import "package:fs_shim/fs.dart";

import "safe_command.dart";
import "shell_command_analysis.dart" show readableWords;

/// The git subcommands a command grant policy vouches for: mutations whose
/// writes are the repo's own metadata — refs, objects, the index, worktree
/// bookkeeping — and nothing a user would want a banner about. Anything not
/// listed stands down to the banner path in every mode: pushes and resets
/// and stashes — and the `config`, `remote` and `submodule` writes, whose
/// edits reach `.git/config`, where a planted hook or fsmonitor would run
/// under the user's own git outside this sandbox, and an `init` rerun with
/// `--template`, which copies the template's files into `.git/hooks` the
/// same way.
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

final _worktreeBoundary = RegExp(r"/\.git/worktrees(?:/|$)");
final _gitdirLine = RegExp(r"^gitdir:\s*(.+)$", multiLine: true);

/// What moves the shell's own directory, wherever it stands in a segment:
/// past the lead — `{ cd x; }`, `then cd x` — it is one the tracker does not
/// follow.
const _movers = {"cd", "pushd", "popd"};

/// What runs a script in the shell itself, which may move it anywhere.
const _sourcers = {"eval", "source", "."};

/// What the grant layer answers for one command: the profile of each
/// segment and, for every git segment warranted by the policy — the plain
/// mutations and the read-only ones alike, git's reads being writes at the
/// kernel — the grant the answer is backed by. One computation, read by
/// both the approval gate and the sandbox composer — the invariant that
/// makes the pair honest is that no grant reaches the sandbox that the gate
/// did not read as coverage, and no coverage claims a grant that is not
/// here.
class CommandGrants {
  const CommandGrants({required this.profiles, required this.gitGrants});

  /// One [SegmentProfile] per segment, in order.
  final List<SegmentProfile> profiles;

  /// The git grant for each warranted segment that found a repository. A
  /// warranted segment with none — the command runs somewhere with no repo
  /// above it — is not covered, for the grant being the thing the answer is
  /// honest about.
  final Map<int, GitGrant> gitGrants;
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

/// Whether the policy answers a grant beside a git segment at all: any git
/// command the classification lets past the banner needs its repository's
/// git dir — the mutating ones because writing refs is the work, the
/// read-only ones because git's reads are not read-only at the kernel (a
/// `git status` refreshes the index; `git diff` reads it; a fetch takes
/// locks). What is left out — pushes, resets, the config/remote writes the
/// vouch list's doc names — stands down to the banner path first.
bool grantWarranted(SegmentProfile profile) =>
    (profile.reach == SegmentReach.nonModifying &&
        profile.program == "git") ||
    segmentVouched(profile);

/// Assesses one command. The expensive part is the directory read walking
/// up for the repo, so the answer is a value both
/// the gate and the composer recompute for the same inputs; nothing is held
/// between calls to drift. The walk within one call is memoised by
/// directory, which answers the same question once for a compound that
/// names the same repo twice and still holds no state after the call.
Future<CommandGrants> commandGrantsFor(CommandGrantsInput input) async {
  final profiles = [
    for (final segment in input.segments) profileSegment(segment),
  ];
  final workDirs = List<String?>.filled(profiles.length, null);
  var cwd = input.start;
  var lost = false;
  for (var i = 0; i < profiles.length; i++) {
    final profile = profiles[i];
    if (lost) continue;
    if (!profile.modelable) {
      // A segment the words cannot name may still have moved the shell: a
      // `cd` with an expansion inside it sends the directory somewhere
      // unnameable, and no vouch survives standing on a directory the parse
      // never named.
      final words = readableWords(input.segments[i]);
      if (words.any(_movers.contains) ||
          _sourcers.contains(words.firstOrNull)) {
        lost = true;
      }
      continue;
    }
    if (profile.words.isEmpty) continue;
    final lead = profile.words.first.toLowerCase();
    if (_sourcers.contains(lead) ||
        (lead != "cd" &&
            lead != "pushd" &&
            profile.words.any(_movers.contains))) {
      lost = true;
      continue;
    }
    if (lead == "popd" || (lead == "pushd" && profile.words.length == 1)) {
      // A bare `pushd` swaps the tracker's stack, which this reads nothing
      // of, and `popd`'s destination is the same unknown.
      lost = true;
      continue;
    }
    if (lead == "cd" || lead == "pushd") {
      final next = await _resolveCd(input.fs, input.home, cwd, profile.words);
      if (next == null) {
        // Lost: this and everything after runs where the parse cannot say.
        // A cd that fails short-circuits the rest under `&&`, but a `;`
        // compound runs on in the old directory — so the tracker only
        // stands where the target exists, and loses otherwise.
        lost = true;
        continue;
      }
      cwd = next;
      workDirs[i] = cwd;
      continue;
    }
    workDirs[i] = cwd;
  }
  final gitGrants = <int, GitGrant>{};
  final walked = <String, GitGrant?>{};
  for (var i = 0; i < profiles.length; i++) {
    final profile = profiles[i];
    if (!grantWarranted(profile)) continue;
    final dir = workDirs[i];
    if (dir == null) continue;
    // The same repo asked for twice in one compound — `git add x && git
    // commit -m y` — is one walk. Only the walk-up is
    // memoised: an explicit `--git-dir` resolves against the segment's own
    // directory, so its answer is not portable between segments.
    GitGrant? grant;
    if (_gitDirOverride(profile.words) == null) {
      if (!walked.containsKey(dir)) {
        walked[dir] = await gitGrantFor(
          input.fs,
          dir,
          input.home,
          profile.words,
        );
      }
      grant = walked[dir];
    } else {
      grant = await gitGrantFor(input.fs, dir, input.home, profile.words);
    }
    if (grant != null) gitGrants[i] = grant;
  }
  return CommandGrants(profiles: profiles, gitGrants: gitGrants);
}

/// Whether the git grant policy vouches for [profile]: a `git` mutation in
/// one of the plain shapes, not the guarded deletions and renames and never
/// a `-c`. Reached through [grantWarranted]'s fallthrough — a non-git or
/// non-vouched profile arriving is the answer false.
bool segmentVouched(SegmentProfile profile) =>
    profile.modelable &&
    profile.program == "git" &&
    plainGitUse(profile.words, vouchedGitSubcommands);

/// A warranted git segment's grant. [gitDir] is the repository the command
/// works against — the walk-up's finding, or the main repository's `.git`
/// where the cwd is a linked worktree, the answer a
/// `git rev-parse --absolute-git-dir` prints for both — and [paths] names
/// that directory itself, granted wholesale: git's working writes are not
/// just the children a listing would find, they are new files made in the
/// directory's own root — `.git/index.lock` under every ref-refresh,
/// `COMMIT_EDITMSG` under a commit — and creating one needs make-rights on
/// the parent. Landlock has no deny to carve a child back out of a granted
/// parent, so the protection of `.git/config` and `.git/hooks` is not the
/// sandbox's work here — it is the vouch list's and the mode gate's, as the
/// vouch list's own doc tells it.
class GitGrant {
  const GitGrant({required this.gitDir, required this.paths});

  final String gitDir;

  final List<String> paths;
}

/// Discovers the git dir one git segment ([words]) writes into, from
/// [cwd], and grants it. Null where there is nothing to grant — no repo
/// above [cwd], a pointer that makes no sense, an explicit gitdir that
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
  if (gitDir == null) {
    return null;
  }
  // The worktree's own checkout directory is deliberately outside this
  // grant: a worktree add checks out into where its argument names, and
  // whether that is inside an already-granted root — the workspace,
  // usually — is the sandbox's ordinary answer, with the re-prompt behind
  // it.
  return GitGrant(gitDir: gitDir, paths: [gitDir]);
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
      final match = _gitdirLine.firstMatch(text);
      if (match == null) return null;
      final pointed = _resolve(fs, dir, match.group(1)!.trim(), null);
      if (pointed == null) return null;
      final boundary = _worktreeBoundary.firstMatch(pointed);
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
    return fs.path.normalize(
      "$home${target == "~" ? "" : target.substring(1)}",
    );
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
  if (target == "-" || target.length > 1 && target.startsWith(r"$")) {
    return null;
  }
  final resolved = _resolve(fs, cwd, target, home);
  if (resolved == null) return null;
  if (!await fs.directory(resolved).exists()) return null;
  return resolved;
}
