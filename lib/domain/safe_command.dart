/// How much of a command's effect its own text proves, decided per segment
/// before anything asks a model or a human. Where [ShellCommandAnalysis]
/// answers "can this parse be answered for at all", this answers the narrower
/// question the approval tiers want: is this segment provably non-modifying;
/// is it a fetch the network rules cover; and if neither, is it one of the
/// command families a grant policy vouches for. The safe side is the
/// deterministic side, so any segment this cannot fully parse stands down to
/// the banner path rather than being guessed at.
library;

import "shell_command_analysis.dart" show plainWords;

/// Programs whose every flag is a read, so any invocation of one is
/// non-modifying apart from its redirects. Deliberately small: anything with
/// a mode-set, output-file or execute-capable flag is guarded or absent.
const nonModifyingPrograms = {
  "ls",
  "cd",
  "cat",
  "head",
  "tail",
  "wc",
  "which",
  "type",
  "diff",
  "stat",
  "du",
  "df",
  "pwd",
  "echo",
  "printf",
  "true",
  "uname",
  "whoami",
  "id",
  "basename",
  "dirname",
  "realpath",
  "readlink",
  "tree",
  "free",
  "lscpu",
  "lsblk",
  "grep",
  "egrep",
  "fgrep",
  "printenv",
  "comm",
  "cmp",
  "cut",
  "paste",
  "tr",
  "uniq",
  "cksum",
  "md5sum",
  "sha1sum",
  "sha256sum",
  "sha512sum",
  "nl",
  "tac",
  "rev",
  "whereis",
};

/// Programs non-modifying only when none of these words appear among their
/// arguments — the write-, execute- or set-capable flags of otherwise safe
/// tools. A listed flag present means the segment is not proven read-only.
const guardedFlags = <String, Set<String>>{
  "sort": {"-o", "--output"},
  "tree": {"-o"},
  "file": {"-m", "--magic-file", "-f", "--files-from", "-C", "--compile"},
  "find": {
    "-delete",
    "-exec",
    "-execdir",
    "-ok",
    "-okdir",
    "-fprintf",
    "-fprint",
    "-fprint0",
    "-fls",
    "-files0-from",
  },
};

/// The read-only subcommands of `git`. The command carries its own guards:
/// flags and sub-sub-commands of these that write are in [gitGuardedArgs],
/// and the two whose bare positional argument creates a thing — `git branch
/// feature`, `git tag v1` — take the positional rule in [plainGitUse].
const _gitNonModifyingSubcommands = {
  "status",
  "log",
  "diff",
  "show",
  "rev-parse",
  "blame",
  "describe",
  "ls-files",
  "ls-remote",
  "ls-tree",
  "cat-file",
  "symbolic-ref",
  "reflog",
  "remote",
  "branch",
  "tag",
  "worktree",
  "help",
  "version",
  "count-objects",
};

/// Git arguments that make a read-only-subcommand segment mutating: the
/// sub-sub-commands and flags that write refs, config or the index. The
/// grant policy reads the same table to keep its deletions and renames out
/// of a vouch.
const gitGuardedArgs = {
  "branch": {
    "-d",
    "-D",
    "-m",
    "-M",
    "-c",
    "-C",
    "-u",
    "-f",
    "--edit-description",
    "--force",
    "--delete",
    "--set-upstream-to",
    "--unset-upstream",
  },
  "tag": {"-a", "-s", "-d", "-f", "-m", "-F", "--force"},
  "diff": {"--output"},
  "log": {"--output"},
  "show": {"--output"},
  "reflog": {"delete", "-delete", "expire"},
  // Re-running `git init` on an existing repository copies the template's
  // files — the hooks the wholesale grant covers — and a vouch would do it
  // without a banner.
  "init": {"--template"},
  "remote": {
    "add",
    "remove",
    "rename",
    "set-url",
    "set-head",
    "set-branches",
    "prune",
    "update",
  },
  "worktree": {"prune", "remove", "lock", "unlock", "move", "repair"},
};

/// Whether any of [args] trips [guards] — the flags' plain forms and their
/// `--flag=value` spellings. One predicate for every reader of the guard
/// tables, so the flag tables cannot mean two things to two callers.
bool anyGuardedArg(Set<String>? guards, Iterable<String> args) {
  if (guards == null) return false;
  return args.any((w) {
    final lower = w.toLowerCase();
    return guards.contains(lower) || guards.any((g) => lower.startsWith("$g="));
  });
}

/// The fetcher family: shell programs whose work is reaching a host, so a
/// segment starting with one of these is consulted under the same rules the
/// `webfetch` tool answers to. Package managers are deliberately absent —
/// their network half comes attached to installs, which are mutations.
const fetchFamilyPrograms = {"curl", "wget", "wget2", "http", "https"};

/// How much one segment's effect is proven by its own text.
enum SegmentReach {
  /// Reads something and writes nothing the parse could name outside the
  /// exempted descriptors — nothing left to ask about.
  nonModifying,

  /// A [fetchFamilyPrograms] program: consulted under the network rules
  /// with [SegmentProfile.url].
  network,

  /// Everything else — the banner path decides, whatever the mode.
  other,
}

/// One segment's answer. [modelable] false means the words could not be read
/// as plain ones — an expansion, a substitution, an unbalanced quote — and
/// the segment stands down; nothing downstream vouches for what it cannot
/// tokenize.
class SegmentProfile {
  const SegmentProfile._(
    this.modelable,
    this.reach,
    this.program,
    this.words,
    this.url,
  );

  /// The parse failed: treat as [SegmentReach.other] everywhere.
  const SegmentProfile.unmodeled()
    : this._(false, SegmentReach.other, "", const [], null);

  final bool modelable;

  final SegmentReach reach;

  /// The first word, lowercased and as written — `""` when there is none.
  final String program;

  /// The segment's words, where it parsed. The grant policies read the
  /// subcommand shape off these.
  final List<String> words;

  /// The URL for a [SegmentReach.network] segment, scheme-normalized so the
  /// same consult takes it whatever spelling named the host.
  final String? url;
}

/// Classifies [segment]. Reads the words the whole-command parse's own
/// tokenizer gives ([plainWords]), so a quote or a here-document means the
/// same here as there, and stands down on everything they cannot name.
SegmentProfile profileSegment(String segment) {
  final parsed = plainWords(segment);
  if (parsed == null) {
    return const SegmentProfile.unmodeled();
  }
  final words = parsed;
  if (words.isEmpty) return const SegmentProfile.unmodeled();
  final program = words.first.toLowerCase();
  if (_diskRedirect(words)) {
    // A redirect to a file the segment names is a write this layer sees —
    // the exemptions are what every command throws output away through.
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  if (fetchFamilyPrograms.contains(program)) {
    final url = _urlOf(words);
    if (url == null) {
      return SegmentProfile._(true, SegmentReach.other, program, words, null);
    }
    return SegmentProfile._(true, SegmentReach.network, program, words, url);
  }
  if (program == "env" && words.length == 1) {
    return SegmentProfile._(
      true,
      SegmentReach.nonModifying,
      program,
      words,
      null,
    );
  }
  if (program == "git") {
    return _gitProfile(program, words);
  }
  // `uniq IN OUT` writes OUT; with one file or none it only reads.
  if (program == "uniq" &&
      words.skip(1).where((w) => !w.startsWith("-")).length > 1) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  if (nonModifyingPrograms.contains(program) &&
      !anyGuardedArg(guardedFlags[program], words.skip(1))) {
    return SegmentProfile._(
      true,
      SegmentReach.nonModifying,
      program,
      words,
      null,
    );
  }
  return SegmentProfile._(true, SegmentReach.other, program, words, null);
}

/// Whether `git` [words] are a plain use of one of [subcommands]: no `-c`
/// (configuration in the command decides what later git tools run), no
/// guarded argument, and no bare name after `branch` or `tag` — `git branch
/// feature` writes a ref as surely as `-d` deletes one, and the guard table
/// cannot name a shape a flag never carries. The read-only tier and the
/// grant policy's vouch both hold git to this.
bool plainGitUse(List<String> words, Set<String> subcommands) {
  if (words.length < 2 || words[1] == "-c") return false;
  final sub = words[1].toLowerCase();
  if (!subcommands.contains(sub)) return false;
  final tail = words.skip(2);
  if (anyGuardedArg(gitGuardedArgs[sub], tail)) return false;
  return !((sub == "branch" || sub == "tag") &&
      tail.any((w) => !w.startsWith("-")));
}

SegmentProfile _gitProfile(String program, List<String> words) {
  if (!plainGitUse(words, _gitNonModifyingSubcommands)) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  final sub = words[1].toLowerCase();
  final tail = words.sublist(2);
  // A second-level subcommand reads: `remote add`, `worktree remove`, and
  // `symbolic-ref` with a target all write through the guard list; the read
  // shapes name nothing to write to.
  if (sub == "symbolic-ref" && tail.length >= 2) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  if (sub == "worktree" && tail.isNotEmpty && tail.first != "list") {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  return SegmentProfile._(
    true,
    SegmentReach.nonModifying,
    program,
    words,
    null,
  );
}

/// Whether the segment's words carry a redirect whose target names a file:
/// the ops the words keep — `>` and `>>` — are checked against the word
/// that follows them. Not writes: the files every command throws output
/// away through, and fd duplication — the tokenizer keeps the `&` as its
/// own word, so `2>&1` reads `>`, `&`, `1`. Only a descriptor (or `-`)
/// after the `&` is one: `>&file` writes the file. A bare `> 2` stays a
/// write too: in the shell that is a file named `2`.
bool _diskRedirect(List<String> words) {
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (!(w == ">" || w == ">>")) continue;
    var target = i + 1 < words.length ? words[i + 1].toLowerCase() : "";
    if (target == "&") {
      target = i + 2 < words.length ? words[i + 2] : "";
      if (target == "-" || RegExp(r"^\d+$").hasMatch(target)) continue;
    } else if (RegExp(r"^&\d+$").hasMatch(target)) {
      continue;
    }
    if (target.isEmpty ||
        target == "/dev/null" ||
        target == "/dev/stdout" ||
        target == "/dev/stderr") {
      continue;
    }
    return true;
  }
  return false;
}

final _scheme = RegExp(r"^[a-zA-Z][a-zA-Z0-9+.-]*://");

/// The URL of a fetcher segment: the first argument that names one by
/// scheme, or — the family's bare-host shape, `curl example.com` — the
/// first argument that could be a host, spelled with the scheme the family
/// itself defaults to. Null where none is confidently nameable, which is
/// the same answer "consult nothing, let the mode ask".
String? _urlOf(List<String> words) {
  for (var i = 1; i < words.length; i++) {
    final w = words[i];
    if (_scheme.hasMatch(w)) return w;
  }
  for (var i = 1; i < words.length; i++) {
    final w = words[i];
    if (w.startsWith("-")) continue;
    if (w != words.first && (w.contains(".") || w.contains(":"))) {
      return "http://$w";
    }
  }
  return null;
}
