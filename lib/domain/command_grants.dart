import "package:fs_shim/fs.dart";

import "safe_command.dart";

/// The git subcommands a command grant policy vouches for: mutations whose
/// writes are the repo's own metadata — refs, objects, the index, worktree
/// bookkeeping — and nothing a user would want a banner about. Anything not
/// listed stands down to the banner path in every mode: pushes and resets
/// and stashes, the config and remote writes that would land in the
/// protected half of the grant, and everything else the sandbox is the only
/// boundary behind.
const vouchedGitSubcommands = {
  "add",
  "commit",
  "fetch",
  "pull",
  "merge",
  "cherry-pick",
  "revert",
  "mv",
  "tag",
  "branch",
  "init",
};

/// The children of a git dir a grant names, taken out of the grant. Landlock
/// is additive-only — there is no deny to carve a path out of an allowed
/// directory — so protection is by enumeration: every child of `.git` is
/// granted except these two, which are what turn a repo grant into an
/// escape that runs outside the sandbox later. A hook the user's own next
/// git command executes runs unconfined, and `core.fsmonitor` and
/// `core.pager` are programs the same config edit can have a command run.
const protectedGitChildren = {"config", "hooks"};

/// What the grant layer answers for one command: the profile of each
/// segment, where the segment runs once the command's own `cd`s are
/// tracked, and, for the segments a policy vouches for, the grant the vouch
/// is backed by. One computation, read by both the approval gate and the
/// sandbox composer — the invariant that makes the pair honest is that
/// nothing is vouched for here without a grant under it, and nothing
/// granted that was not vouched.
class CommandGrants {
  const CommandGrants({
    required this.profiles,
    required this.workDirs,
    required this.gitGrants,
  });

  /// One [SegmentProfile] per segment, in order.
  final List<SegmentProfile> profiles;

  /// The directory each segment runs in — the command's `cd`s resolved
  /// against [input.start] — or null where the tracker lost the directory,
  /// which no vouch survives.
  final List<String?> workDirs;

  /// The git grant for each vouched segment that had one. A vouched segment
  /// with none — the command runs somewhere with no repo above it — is not
  /// covered, for the grant being the thing the vouch is honest about.
  final Map<int, GitGrant> gitGrants;

  /// Whether segment [i] has a deterministic cover: the parse proved it
  /// non-modifying, or a vouch is backed by a grant. The callers add what
  /// they know beside this — rule allows for a segment, a network allow.
  bool covers(int i) =>
      profiles[i].reach == SegmentReach.nonModifying ||
      gitGrants.containsKey(i);

  /// Whether every segment is covered by this deterministic half alone.
  bool get allCovered {
    for (var i = 0; i < profiles.length; i++) {
      if (!covers(i)) return false;
    }
    return profiles.isNotEmpty;
  }
}

/// The inputs one command's assessment is made of. [start] is where the
/// shell was standing before the command ran; [home] is what `~` means to
/// it. The segments are the command's, as the parse split them.
class CommandGrantsInput {
  const CommandGrantsInput({
    required this.fs,
    required this.start,
    required this.home,
    required this.segments,
  });

  final FileSystem fs;

  final String start;

  final String? home;

  final List<String> segments;
}

/// Assesses one command. The expensive parts are directory reads — walking
/// up for the repo and listing its `.git` — so the answer is a value both
/// the gate and the composer recompute for the same inputs; nothing is held
/// between calls to drift.
Future<CommandGrants> commandGrantsFor(CommandGrantsInput input) async {
  final profiles = [
    for (final segment in input.segments) profileSegment(segment),
  ];
  final workDirs = <String?>[];
  var cwd = input.start;
  var lost = false;
  for (final profile in profiles) {
    if (lost) {
      workDirs.add(null);
      continue;
    }
    if (!profile.modelable || profile.words.isEmpty) {
      workDirs.add(null);
      continue;
    }
    if (profile.words.first.toLowerCase() == "cd") {
      final next = await _resolveCd(input.fs, input.home, cwd, profile.words);
      if (next == null) {
        // Lost: this and everything after runs where the parse cannot say.
        // A cd that fails short-circuits the rest under `&&`, but a `;`
        // compound runs on in the old directory — so the tracker only
        // stands where the target exists, and loses otherwise.
        workDirs.add(null);
        lost = true;
        continue;
      }
      cwd = next;
      workDirs.add(cwd);
      continue;
    }
    workDirs.add(cwd);
  }
  final gitGrants = <int, GitGrant>{};
  for (var i = 0; i < profiles.length; i++) {
    final profile = profiles[i];
    // A proven non-modifying segment writes nothing worth granting and is
    // covered by its reach; only the grant-backed half is discovered here.
    if (profile.reach == SegmentReach.nonModifying) continue;
    final dir = i < workDirs.length ? workDirs[i] : null;
    if (dir == null || !segmentVouched(profile)) continue;
    final grant = await gitGrantFor(input.fs, dir, input.home, profile.words);
    if (grant != null) gitGrants[i] = grant;
  }
  return CommandGrants(
    profiles: profiles,
    workDirs: workDirs,
    gitGrants: gitGrants,
  );
}

/// Whether the git grant policy vouches for [profile]. A segment the parse
/// already proved non-modifying needs no vouch; a `git` mutation does, and
/// one is given only for the subcommands above, in their plain shapes —
/// `-c` never, and the guarded deletions and renames of `branch` and `tag`
/// not either, the banner being the right place to learn about those.
bool segmentVouched(SegmentProfile profile) {
  if (profile.reach == SegmentReach.nonModifying) return true;
  if (!profile.modelable) return false;
  final words = profile.words;
  if (words.length < 2 || words[0].toLowerCase() != "git") return false;
  if (words[1] == "-c") return false;
  final sub = words[1].toLowerCase();
  if (!vouchedGitSubcommands.contains(sub)) return false;
  final guards = gitGuardedArgs[sub];
  if (guards != null &&
      words.skip(2).any((w) {
        final lower = w.toLowerCase();
        return guards.contains(lower) ||
            guards.any((g) => lower.startsWith("$g="));
      })) {
    return false;
  }
  return true;
}

/// A vouched git segment's grant. [gitDir] is the repository the command
/// works against — the walk-up's finding, or the main repository's `.git`
/// where the cwd is a linked worktree, the answer a
/// `git rev-parse --absolute-git-dir` prints for both — and [paths] is the
/// expandable half: every child of that directory but the protected ones.
class GitGrant {
  const GitGrant({required this.gitDir, required this.paths});

  final String gitDir;

  final List<String> paths;
}

/// Discovers the git dir one vouched `git` segment ([words]) writes into,
/// from [cwd], and expands it. Null where there is nothing to grant — no
/// repo above [cwd], a pointer that makes no sense, an explicit gitdir that
/// names nothing — which is the caller's signal that the segment stands
/// down to the banner path.
Future<GitGrant?> gitGrantFor(
  FileSystem fs,
  String cwd,
  String? home,
  List<String> words,
) async {
  final override = _gitDirOverride(words);
  String? gitDir;
  if (override != null) {
    final resolved = _resolve(fs, cwd, override, home);
    if (resolved == null || !await fs.directory(resolved).exists()) {
      return null;
    }
    gitDir = resolved;
  } else {
    gitDir = await _walkUpForGitDir(fs, cwd);
  }
  if (gitDir == null) return null;
  final paths = <String>[];
  // The worktree's own checkout directory is deliberately outside this
  // grant: a worktree add checks out into where its argument names, and
  // whether that is inside an already-granted root — the workspace,
  // usually — is the sandbox's ordinary answer, with the re-prompt behind
  // it.
  await for (final entity in fs.directory(gitDir).list()) {
    final name = entity.path.split(RegExp(r"[/\\]")).last;
    if (protectedGitChildren.contains(name)) continue;
    paths.add(entity.path);
  }
  return GitGrant(gitDir: gitDir, paths: paths);
}

/// `--git-dir=<path>` or `--git-dir <path>` on the segment, or null.
String? _gitDirOverride(List<String> words) {
  for (var i = 1; i < words.length; i++) {
    final w = words[i];
    if (w == "--git-dir" && i + 1 < words.length) return words[i + 1];
    if (w.startsWith("--git-dir=")) return w.substring("--git-dir=".length);
  }
  return null;
}

/// The `.git` of the repo working above [cwd]: the first `.git` directory
/// walking up — a normal checkout — or a `.git` FILE's pointer resolved,
/// which is a linked worktree's: its `gitdir:` names a directory under the
/// main repository's `.git/worktrees/` and the shared half the command
/// writes into is that main `.git`. A submodule's pointer lands under
/// `/.git/modules/`, which holds its own refs and objects wholesale, so the
/// resolved path itself is the grant.
Future<String?> _walkUpForGitDir(FileSystem fs, String cwd) async {
  var dir = cwd;
  while (true) {
    final dotGit = fs.path.join(dir, ".git");
    final dirEntity = fs.directory(dotGit);
    if (await dirEntity.exists()) return dotGit;
    final fileEntity = fs.file(dotGit);
    if (await fileEntity.exists()) {
      final text = await fileEntity.readAsString();
      final match = RegExp(
        r"^gitdir:\s*(.+)$",
        multiLine: true,
      ).firstMatch(text);
      if (match == null) return null;
      final pointed = _resolve(fs, dir, match.group(1)!.trim(), null);
      if (pointed == null) return null;
      final worktreeBoundary = RegExp(r"/\.git/worktrees(?:/|$)");
      final boundary = worktreeBoundary.firstMatch(pointed);
      if (boundary == null) return pointed;
      return "${pointed.substring(0, boundary.start)}/.git";
    }
    final parent = fs.path.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// Resolves [target] the way a `cd`, an argument or a gitdir pointer means
/// it against [from]: absolute as written, `~` against [home] (null where
/// home is unknown, which is the answer "cannot name it"), relative against
/// [from] — normalized, never made to exist.
String? _resolve(FileSystem fs, String from, String target, String? home) {
  if (target.isEmpty) return null;
  if (target.startsWith("/")) return fs.path.normalize(target);
  if (target == "~" || target.startsWith("~/")) {
    if (home == null) return null;
    return fs.path.normalize(home + (target == "~" ? "" : target.substring(1)));
  }
  return fs.path.normalize(fs.path.join(from, target));
}

/// The cwd `cd`'s [words] leave the tracker at: the bare `cd` against home,
/// the target resolved against [cwd] — null where the target cannot be
/// named plainly or names a directory that is not there.
Future<String?> _resolveCd(
  FileSystem fs,
  String? home,
  String cwd,
  List<String> words,
) async {
  final target = words.length == 1 ? "~" : words[1];
  if (target == "-" || target.length > 1 && target.startsWith("\$")) {
    return null;
  }
  final resolved = _resolve(fs, cwd, target, home);
  if (resolved == null) return null;
  if (!await fs.directory(resolved).exists()) return null;
  return resolved;
}
