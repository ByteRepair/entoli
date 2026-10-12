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
const _guardedFlags = <String, Set<String>>{
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
/// flags and sub-sub-commands of these that write are in [gitGuardedArgs].
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
  "reflog": {"-delete", "expire"},
  "remote": {
    "add",
    "remove",
    "rename",
    "set-url",
    "set-head",
    "set-branches",
    "prune",
  },
  "worktree": {"prune", "remove", "lock", "unlock", "move", "repair"},
};

/// The fetcher family: shell programs whose work is reaching a host, so a
/// segment starting with one of these is consulted under the same rules the
/// `webfetch` tool answers to. Package managers are deliberately absent —
/// their network half comes attached to installs, which are mutations.
const fetchFamilyPrograms = {"curl", "wget", "wget2", "http", "https"};

/// curl arguments that put the fetched bytes or headers on the disk, which a
/// network allow does not by itself vouch for — the sandbox is what bounds
/// where they land.
const _curlDiskArgs = {
  "-o",
  "-O",
  "-c",
  "-C",
  "-d",
  "-D",
  "-F",
  "-J",
  "-K",
  "-T",
  "--data",
  "--data-raw",
  "--data-binary",
  "--data-urlencode",
  "--form",
  "--form-string",
  "--upload-file",
  "--output",
  "--output-dir",
  "--remote-name",
  "--remote-name-all",
  "--remote-header-name",
  "--cookie-jar",
  "--dump-header",
  "--dump-binary",
  "--create-dirs",
  "--config",
  "--trace",
  "--trace-ascii",
};

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
    this.writesDisk,
  );

  /// The parse failed: treat as [SegmentReach.other] everywhere.
  const SegmentProfile.unmodeled(String program)
    : this._(false, SegmentReach.other, program, const [], null, false);

  final bool modelable;

  final SegmentReach reach;

  /// The first word, lowercased and as written — `""` when there is none.
  final String program;

  /// The segment's words, where it parsed. The grant policies read the
  /// subcommand shape off these.
  final List<String> words;

  /// The URL token for a [SegmentReach.network] segment, as written.
  final String? url;

  /// Whether the segment puts bytes on the disk beyond what its redirects
  /// are checked for — a curl `-o`, a plain `wget` — so a network allow
  /// still leaves the write where the sandbox is the boundary.
  final bool writesDisk;
}

/// Classifies [segment]. Reads the surface shape only — quotes and the
/// operators — and stands down on everything its words cannot name.
SegmentProfile profileSegment(String segment) {
  final parsed = _read(segment);
  if (parsed == null) {
    return const SegmentProfile.unmodeled("");
  }
  final words = parsed;
  if (words.isEmpty) return const SegmentProfile.unmodeled("");
  final program = words.first.toLowerCase();
  if (_diskRedirect(words)) {
    // A redirect to a file the segment names is a write this layer sees —
    // except the ones every command throws output away through.
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      true,
    );
  }
  if (fetchFamilyPrograms.contains(program)) {
    final url = _urlOf(words);
    if (url == null) {
      return SegmentProfile._(
        true,
        SegmentReach.other,
        program,
        words,
        null,
        false,
      );
    }
    final disk = _writesDiskFor(program, words);
    return SegmentProfile._(
      true,
      SegmentReach.network,
      program,
      words,
      url,
      disk,
    );
  }
  if (program == "env" && words.length == 1) {
    return SegmentProfile._(
      true,
      SegmentReach.nonModifying,
      program,
      words,
      null,
      false,
    );
  }
  if (program == "git") {
    return _gitProfile(program, words);
  }
  if (nonModifyingPrograms.contains(program) && !_hasGuardedFlag(words)) {
    return SegmentProfile._(
      true,
      SegmentReach.nonModifying,
      program,
      words,
      null,
      false,
    );
  }
  return SegmentProfile._(
    true,
    SegmentReach.other,
    program,
    words,
    null,
    false,
  );
}

SegmentProfile _gitProfile(String program, List<String> words) {
  if (words.length >= 2 && words[1] == "-c") {
    // `git -c core.fsmonitor=<program> ...`: configuration in the command
    // decides what later git tools run, and the parse's whole-command veto
    // catches the assignment on top of this.
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      false,
    );
  }
  final sub = words.length >= 2 ? words[1].toLowerCase() : "";
  if (sub.isEmpty || !_gitNonModifyingSubcommands.contains(sub)) {
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      false,
    );
  }
  final guarded = gitGuardedArgs[sub];
  final tail = words.sublist(2);
  if (guarded != null && tail.any((w) => guarded.contains(w.toLowerCase()))) {
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      false,
    );
  }
  // A second-level subcommand reads: `remote add`, `worktree remove`, and
  // `symbolic-ref` with a target all write through the guard list; the read
  // shapes name nothing to write to.
  if (sub == "symbolic-ref" && tail.length > 2) {
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      false,
    );
  }
  if (sub == "worktree" && tail.isNotEmpty && !{"list"}.contains(tail.first)) {
    return SegmentProfile._(
      true,
      SegmentReach.other,
      program,
      words,
      null,
      false,
    );
  }
  return SegmentProfile._(
    true,
    SegmentReach.nonModifying,
    program,
    words,
    null,
    false,
  );
}

/// Whether any argument trips its program's guard list.
bool _hasGuardedFlag(List<String> words) {
  final guards = _guardedFlags[words.first.toLowerCase()];
  if (guards == null) return false;
  return words.skip(1).any((w) {
    final lower = w.toLowerCase();
    return guards.contains(lower) || guards.any((g) => lower.startsWith("$g="));
  });
}

/// `_read` of a segment: its words, lowercased nowhere — the caller cases
/// where it asks. Null where the words cannot be named plainly: an
/// expansion, a substitution, a quote left open, a grouping — the segment is
/// one the deterministic layer answers for nothing.
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
      case r"$" || "(" || ")":
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
        final two = i + 1 < segment.length ? segment[i + 1] : "";
        if (c == ">" && two == ">") {
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

/// Whether the segment's words carry a redirect whose target names a file:
/// the ops the words keep — `>` and `>>` — are checked against the words
/// that follow them and against exemption forms.
// Redirect targets are judged inside [_diskRedirect]: the ops the words
// keep — `>` and `>>` — are checked against the word that follows them and
// against the exemption forms.
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

/// The redirect targets that are not writes: the descriptors and `/dev/null`
/// a command throws output away through.
bool _isExemptRedirectWord(String word) {
  final w = word.toLowerCase();
  return w == "/dev/null" ||
      w == "/dev/stdout" ||
      w == "/dev/stderr" ||
      w == "&" ||
      w == "1" ||
      w == "2" ||
      w == "&1" ||
      w == "&2" ||
      w == ">&1" ||
      w == ">&2" ||
      RegExp(r"^\d*>&\d?$").hasMatch(w) ||
      RegExp(r"^\d?>&\d?$").hasMatch(w);
}

/// The URL token of a fetcher segment, as written: the first argument that
/// names one by scheme, or — httpie's shape — the first non-argument word
/// after the program that carries a dot or a colon. Null where none is
/// confidently nameable: the segment is one the network rules are not
/// consulted on at all.
String? _urlOf(List<String> words) {
  final scheme = RegExp(r"^[a-zA-Z][a-zA-Z0-9+.-]*://");
  for (var i = 1; i < words.length; i++) {
    final w = words[i];
    if (scheme.hasMatch(w)) return w;
  }
  final program = words.first;
  if (program == "http" || program == "https") {
    for (var i = 1; i < words.length; i++) {
      final w = words[i];
      if (w.startsWith("-")) continue;
      if (w.contains(".") || w.contains(":")) return w;
    }
  }
  return null;
}

/// Whether the fetch program's arguments put bytes on the disk: curl's write
/// flags explicitly, a plain `wget` always (the file it leaves beside the
/// caller is its whole point) unless it names stdout.
bool _writesDiskFor(String program, List<String> words) {
  if (program == "wget" || program == "wget2") {
    for (var i = 1; i < words.length; i++) {
      final w = words[i];
      if (w == "-O" &&
          i + 1 < words.length &&
          {"-", "/dev/stdout", "/dev/stderr"}.contains(words[i + 1])) {
        return false;
      }
      if (w == "--output-document" &&
          i + 1 < words.length &&
          words[i + 1] == "-") {
        return false;
      }
      if (w.startsWith("--output-document=") &&
          {
            "=-",
            "=/dev/stdout",
            "=/dev/stderr",
          }.any((f) => w == "--output-document${f.substring(1)}")) {
        return false;
      }
    }
    return true;
  }
  if (program == "http" || program == "https") {
    // httpie: reads to stdout unless downloading or writing a body that
    // came from a file this layer does not read — the conservative answer
    // is a disk write wherever a flag suggests one.
    return words
        .skip(1)
        .any(
          (w) =>
              _curlDiskArgs.contains(w.toLowerCase()) ||
              (w.startsWith("--") &&
                  _curlDiskArgs.any(
                    (a) => a.startsWith("--") && w.toLowerCase().startsWith(a),
                  )),
        );
  }
  return words.skip(1).any((w) {
    final lower = w.toLowerCase();
    if (_curlDiskArgs.contains(lower)) return true;
    if (lower.startsWith("--")) {
      return _curlDiskArgs.any(
        (a) => a.startsWith("--") && lower.startsWith(a),
      );
    }
    return false;
  });
}
