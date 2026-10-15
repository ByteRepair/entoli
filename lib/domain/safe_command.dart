/// How much of a command's effect its own text proves, decided per segment
/// before anything asks a model or a human. Where [ShellCommandAnalysis]
/// answers "can this parse be answered for at all", this answers the narrower
/// question the approval tiers want: is this segment provably non-modifying;
/// is it a fetch the network rules cover; and if neither, is it one of the
/// command families a grant policy vouches for. The safe side is the
/// deterministic side, so any segment this cannot fully parse stands down to
/// the banner path rather than being guessed at.
library;

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
/// feature`, `git tag v1` — take the positional rule in [_gitProfile].
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
  },
  "tag": {"-a", "-s", "-d", "-f", "-m", "-F", "--force"},
  "diff": {"--output"},
  "log": {"--output"},
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

/// Classifies [segment]. Reads the surface shape only — quotes and the
/// operators — and stands down on everything its words cannot name.
SegmentProfile profileSegment(String segment) {
  final parsed = _read(segment);
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

SegmentProfile _gitProfile(String program, List<String> words) {
  if (words.length >= 2 && words[1] == "-c") {
    // `git -c core.fsmonitor=<program> ...`: configuration in the command
    // decides what later git tools run, and the parse's whole-command veto
    // catches the assignment on top of this.
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  final sub = words.length >= 2 ? words[1].toLowerCase() : "";
  if (sub.isEmpty || !_gitNonModifyingSubcommands.contains(sub)) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  final tail = words.sublist(2);
  if (anyGuardedArg(gitGuardedArgs[sub], tail)) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
  // The two subcommands whose plain positional argument creates a thing:
  // `git branch feature` writes refs/heads/feature as surely as -d deletes
  // one, and the guard table cannot name a shape a flag never carries.
  if ((sub == "branch" || sub == "tag") &&
      tail.any((w) => !w.startsWith("-"))) {
    return SegmentProfile._(true, SegmentReach.other, program, words, null);
  }
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

/// The redirect targets that are not writes: the files every command throws
/// output away through, and the fd-duplication forms — whose marker is the
/// `&` the tokenizer keeps as its own word, so `2>&1` reads as `>` with the
/// target `&`. A bare `> 2` stays a write: in the shell that is a file
/// named `2`, not a descriptor.
final _fdTarget = RegExp(r"^&\d*$");

bool _isExemptRedirectWord(String word) {
  final w = word.toLowerCase();
  return w == "/dev/null" ||
      w == "/dev/stdout" ||
      w == "/dev/stderr" ||
      _fdTarget.hasMatch(w);
}

/// Whether the segment's words carry a redirect whose target names a file:
/// the ops the words keep — `>` and `>>` — are checked against the word
/// that follows them and against the exemption forms.
bool _diskRedirect(List<String> words) {
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (!(w == ">" || w == ">>")) continue;
    final target = i + 1 < words.length ? words[i + 1] : "";
    if (target.isEmpty || _isExemptRedirectWord(target)) continue;
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

/// `_read` of a segment: its words. Null where the words cannot be named
/// plainly — an expansion, a substitution, a backtick, a quote left open, a
/// grouping — the segment is one the deterministic layer answers for
/// nothing, the same answer the whole-command parse gives its own shapes.
List<String>? _read(String segment) {
  final words = <String>[];
  final current = StringBuffer();
  String? quote;
  void flush() {
    final text = current.toString();
    if (text.trim().isNotEmpty) words.add(text.trim());
    current.clear();
  }

  for (var i = 0; i < segment.length; i++) {
    final c = segment[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (quote == '"' && c == r"$") {
        // Double quotes hide the operator from the shell's tokenizer but
        // not the expansion from the shell: the word inside is still one
        // the parse cannot name.
        return null;
      } else {
        current.write(c);
      }
      continue;
    }
    switch (c) {
      case "'":
        quote = "'";
      case '"':
        quote = '"';
      case r"$" || "(" || ")" || "`":
        return null;
      case "\\":
        if (i + 1 < segment.length) current.write(segment[++i]);
      case " " || "\t":
        flush();
      case ">" || "<" || "&" || "|":
        // Operators become words of their own, with the target word after
        // them, so the redirect check reads `ls > /tmp/x` and `ls >/tmp/x`
        // the same. `>>` stays one op; `&` `|` mean nothing outside quotes
        // at this layer and are kept as the words they would glue into.
        if (c == ">" && i + 1 < segment.length && segment[i + 1] == ">") {
          flush();
          words.add(">>");
          i++;
        } else {
          flush();
          words.add(c);
        }
      default:
        current.write(c);
    }
  }
  flush();
  return words;
}
