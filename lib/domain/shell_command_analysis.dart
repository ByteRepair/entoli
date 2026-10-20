/// What a shell command parses to, decided before anything asks a model about
/// it. The approval regime reads command text, and a command's text can lie —
/// an `eval` built out of pieces, a redirect buried in a substitution — so the
/// deterministic layer answers for the commands it can model and refuses the
/// rest. The safe side is the deterministic side: a command whose write
/// behaviour this cannot answer for is not run, and the reason is worded so
/// the model can rewrite around it.
library;

/// One command's parse. [isWindows] is the answer of a platform whose shell
/// this does not model: nothing is classified there statically, which is what
/// a driver without a parse owes the user (issue #248 carries the real one).
class ShellCommandAnalysis {
  ShellCommandAnalysis._({
    required this.modelable,
    required this.unmodelableReasons,
    required this.escalationReasons,
    required this.command,
  });

  factory ShellCommandAnalysis.parse(String command, {bool isWindows = false}) {
    if (isWindows) {
      return ShellCommandAnalysis._(
        modelable: false,
        unmodelableReasons: const ["commands on this platform are not analyzed"],
        escalationReasons: const [],
        command: command,
      );
    }

    final reasons = <String>[];
    final escalations = <String>[];
    final tokens = _tokenize(command, reasons);
    if (reasons.isNotEmpty ||
        !_escalate(_Pipeline._of(tokens), escalations, reasons, "")) {
      return ShellCommandAnalysis._(
        modelable: false,
        unmodelableReasons: List.unmodifiable(reasons),
        escalationReasons: const [],
        command: command,
      );
    }
    return ShellCommandAnalysis._(
      modelable: true,
      unmodelableReasons: const [],
      escalationReasons: List.unmodifiable(escalations),
      command: command,
    );
  }

  /// False where the parse is not complete enough to answer for the command:
  /// an unterminated quote, an unbalanced substitution, a form this parser
  /// does not take. False means escalate, never guess.
  final bool modelable;

  /// Why [modelable] is false, worded so a model can rewrite around it.
  final List<String> unmodelableReasons;

  /// What the parse found that an automatic decision cannot stand on.
  final List<String> escalationReasons;

  /// The sentence the model reads when this was escalated, or null where
  /// nothing needs saying. Not a bare refusal: the reasons are named, the
  /// command's segments are offered where the parse saw them, and the way out
  /// — split the command, or write the script to the workspace — is spelled
  /// out, so the model rewrites instead of retrying the same shape.
  String? get escalationNote {
    final all = [...unmodelableReasons, ...escalationReasons];
    if (all.isEmpty) return null;
    final segments = modelableSegments;
    final segmentAdvice =
        segments == null || segments.length < 2
            ? ""
            : "\nSegments the command parses to, run each as its own bash "
                "call instead:\n${[for (final s in segments) "- $s"].join("\n")}";
    return "Not run: this command cannot be checked as one piece. The parse "
        "found:\n${[for (final r in all) "- $r"].join("\n")}\n"
        "A compound command is judged segment by segment, and one the parse "
        "cannot model is judged for nothing — no rule and no classifier can "
        "allow it. Rewrite it so what it does is plain, or split it into "
        "separate bash calls, one per step."
        "$segmentAdvice"
        "\nA script too long to inline may be written to the workspace with "
        "the write tool and run by its path.";
  }

  /// The top-level pieces the parse could see, where it got far enough to see
  /// them. Null where the tokenizer failed outright — an unterminated quote,
  /// a substitution never closed — there being nothing reliable to name.
  /// Computed on first read: the segments are consumed by the refusal note
  /// and by per-segment rule matching, never by a command that parsed clean.
  List<String>? get modelableSegments {
    if (unmodelableReasons.isNotEmpty) return null;
    return _segments ??= _segmentsOf(command);
  }

  /// The command the parse ran over, kept for the lazy split above.
  final String command;
  List<String>? _segments;
}

/// Adds to [out] what in [parsed] an automatic decision cannot stand on, and
/// walks every substitution in its words as a command of its own — so `echo
/// $(cat ~/.ssh/id_ed25519)` is a read the parse can name, and a redirect or
/// assignment inside one counts too. [where] says where it was found. False
/// where a substitution does not tokenize; [reasons] then says why.
bool _escalate(
    _Pipeline parsed, List<String> out, List<String> reasons, String where) {
  // An assignment to a write-deciding name rewrites the environment the
  // parse answered for; one to a git include redirects git's configuration.
  for (final name in parsed.assignments.keys) {
    if (writeTargetVars.contains(name)) {
      out.add("sets $name$where, which changes where writes and tools land");
    }
  }
  for (final redirect in parsed.redirects) {
    // An input redirect is a read; a here-document's "target" is a delimiter
    // word, not a path. Both are the sandbox's to answer for.
    if (redirect.fromInput) continue;
    final target = redirect.target;
    if (target == null) {
      // `&>` with no file, or a target the parse could not resolve.
      if (!redirect.fdOnly) out.add("cannot tell where the redirect$where writes");
    } else if (target.any((piece) => piece is _Substitution)) {
      out.add("redirects$where through a substitution, so the parse cannot "
          "name the file");
    } else if (target.whereType<_Expansion>().firstOrNull case final e?) {
      // Where the file lands depends on the environment: the sandbox's
      // answer to make, not the parse's guess.
      out.add("redirects$where through \$${e.name}, so the parse cannot "
          "name the file");
    }
  }
  for (final word in parsed.words) {
    for (final piece in word.whereType<_Substitution>()) {
      final inner = _tokenize(piece.source, reasons);
      if (reasons.isNotEmpty ||
          !_escalate(_Pipeline._of(inner), out, reasons, " inside a substitution")) {
        return false;
      }
    }
  }
  return true;
}

/// The top-level pieces [command] parses to, split on the operators the
/// grammar takes and ignoring anything inside a quote or a substitution —
/// those are one segment's own content. For the refusal note, naming what
/// the model did write where the parse can see it.
List<String> _segmentsOf(String command) {
  final segments = <String>[];
  final current = StringBuffer();
  var depth = 0;
  var quote = "";
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (quote.isNotEmpty) {
      current.write(c);
      if (c == quote && (i == 0 || command[i - 1] != "\\")) quote = "";
      continue;
    }
    if (c == "'" || c == "\"") {
      quote = c;
      current.write(c);
      continue;
    }
    if (c == "(" || c == r"$") {
      depth++;
      current.write(c);
      continue;
    }
    if (c == ")") {
      depth--;
      current.write(c);
      continue;
    }
    if (depth == 0 && c == "\\") {
      // A backslash escapes the next character; both belong to the segment.
      current.write(c);
      if (i + 1 < command.length) current.write(command[++i]);
      continue;
    }
    if (depth == 0 && (c == "|" || c == "&" || c == ";" || c == "\n")) {
      if (current.toString().trim().isNotEmpty) {
        segments.add(current.toString().trim());
      }
      current.clear();
      // `&&` and `||` swallow their second character.
      if (i + 1 < command.length && command[i + 1] == c) i++;
      continue;
    }
    current.write(c);
  }
  if (current.toString().trim().isNotEmpty) {
    segments.add(current.toString().trim());
  }
  return segments;
}

/// Whether [command] reads or writes a file the way the file tools would:
/// `cat`, `head`, `tail`, `nl`, `less` or `more` naming a file rather than
/// filtering a pipe, `sed` given a file or `-i`, or `echo`, `printf` or `cat`
/// writing one through a redirect. A guess for a reminder, never a gate.
bool isFileToolWork(String command) {
  const readers = {"cat", "head", "tail", "nl", "less", "more"};
  const writers = {"echo", "printf", "cat"};
  final tokens = _tokenize(command, <String>[]);
  var words = <String?>[];
  var piped = false;
  var redirected = false;
  var target = false;
  var outTarget = false;

  bool judge() {
    final rest = words.skipWhile((w) => w != null && _isAssignmentWord(w));
    final name = rest.firstOrNull?.split("/").last;
    if (name == null) return false;
    final args = rest.skip(1).whereType<String>();
    final operands = args.where((a) => !a.startsWith("-")).length;
    if (redirected && writers.contains(name)) return true;
    if (readers.contains(name)) return !piped && operands > 0;
    if (name == "sed") {
      return args.any((a) => a.startsWith("-i") || a == "--in-place") ||
          (!piped && operands >= 2);
    }
    return false;
  }

  for (final tok in tokens) {
    if (tok.kind == _TokKind.word) {
      if (target) {
        if (outTarget && _plainOf(tok) != "/dev/null") redirected = true;
        target = false;
      } else {
        words.add(_plainOf(tok));
      }
      continue;
    }
    switch (tok.text) {
      case "|" || "||" || "&&" || ";" || "&" || ";;" || "\n":
        if (judge()) return true;
        words = [];
        piped = tok.text == "|";
        redirected = false;
      case ">" || ">>" || "&>" || "&>>":
        target = true;
        outTarget = true;
      case "<" || "<<" || "<<<":
        target = true;
        outTarget = false;
    }
  }
  return judge();
}

/// Variables that decide where a command's writes, reads or tools land.
/// Assigning one in a command is an escalation, because the parse answers for
/// what the command does under the environment it was handed and one of these
/// rewrites that environment under the parse.
const writeTargetVars = {
  "HOME",
  "CDPATH",
  "XDG_CONFIG_HOME",
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_COMMON_DIR",
  "GIT_OBJECT_DIRECTORY",
  "GIT_INDEX_FILE",
  "GIT_CONFIG_COUNT",
  "PATH",
  "LD_PRELOAD",
  "SHELL",
  "BASH_ENV",
  "ENV",
  "ZDOTDIR",
  "TMPDIR",
};

// ---------------------------------------------------------------------------
// The parser. POSIX enough for the commands this app's models write: words,
// quotes, variables, redirects, pipes, sequencing operators, command and
// arithmetic substitutions, here-documents. Deliberately not a whole shell:
// anything outside this shape is an escalation, not a guess.
// ---------------------------------------------------------------------------

enum _TokKind { word, op }

/// A word is a list of pieces: [String]s for the literal text and
/// [_Substitution]s where a `$( … )` was read. Operators are their own text.
class _Tok {
  const _Tok.op(this.text)
      : kind = _TokKind.op,
        pieces = null;
  const _Tok.word(this.pieces)
      : kind = _TokKind.word,
        text = "";
  final _TokKind kind;
  final String text;
  final List<Object>? pieces;
}

class _Substitution {
  const _Substitution(this.source);
  final String source;
}

/// One parsed pipeline: the commands a pipe/`;`/`&&`/`||` sequence separates,
/// their redirects and their leading assignments.
class _Pipeline {
  _Pipeline._(this.words, this.redirects, this.assignments);

  factory _Pipeline._of(List<_Tok> tokens) {
    final words = <List<Object>>[];
    final redirects = <_Redirect>[];
    final assignments = <String, String>{};
    var current = _Simple();
    var expectWord = false;

    void endCommand() {
      if (current.words.isNotEmpty ||
          current.redirects.isNotEmpty ||
          current.assignments.isNotEmpty) {
        words.addAll(current.words);
        redirects.addAll(current.redirects);
        assignments.addAll(current.assignments);
        current = _Simple();
      }
    }

    for (final tok in tokens) {
      if (tok.kind == _TokKind.word) {
        if (expectWord) {
          final last = current.redirects.removeLast();
          current.redirects
              .add(_Redirect(tok.pieces!, last.fromInput, last.fdOnly));
          expectWord = false;
        } else if (current.words.isEmpty &&
            current.redirects.isEmpty &&
            _isAssignmentWord(_plainOf(tok) ?? "")) {
          final text = _plainOf(tok)!;
          final eq = text.indexOf("=");
          assignments[text.substring(0, eq)] = text.substring(eq + 1);
        } else {
          current.words.add(tok.pieces!);
        }
      } else {
        switch (tok.text) {
          case "||" || "&&" || "|" || ";" || "&" || ";;" || "\n":
            endCommand();
          case ">" || ">>" || "&>" || "&>>":
            expectWord = true;
            current.redirects.add(_Redirect(null, false, false));
          case ">&":
            current.redirects.add(_Redirect(null, false, true));
          case "<" || "<<" || "<<<":
            expectWord = true;
            current.redirects.add(_Redirect(null, true, false));
          case "<&":
            current.redirects.add(_Redirect(null, true, true));
          default:
            // `(`, `)` and the rest: a group or subshell's insides are read
            // as words by this same loop, which is flat but answers for
            // everything in them — the conservative shape for a checker.
            break;
        }
      }
    }
    endCommand();
    return _Pipeline._(words, redirects, assignments);
  }

  final List<List<Object>> words;
  final List<_Redirect> redirects;
  final Map<String, String> assignments;
}

/// A redirect with its target as written, or [fdOnly] where it names a file
/// descriptor rather than a file.
class _Redirect {
  const _Redirect(this.target, this.fromInput, this.fdOnly);
  final List<Object>? target;
  final bool fromInput;
  final bool fdOnly;
}

class _Simple {
  final words = <List<Object>>[];
  final redirects = <_Redirect>[];
  final assignments = <String, String>{};
}

/// An assignment is a word of name=value shape whose name is a valid variable
/// name — a shell name, letters, digits and underscores. A git config key is
/// not one: `include.path=x` is a command word to the shell, and it is `git
/// config`'s business, not an environment rewrite.
bool _isAssignmentWord(String word) {
  final eq = word.indexOf("=");
  if (eq <= 0) return false;
  return RegExp(r"^[A-Za-z_][A-Za-z0-9_]*$").hasMatch(word.substring(0, eq));
}

/// The word's whole text, where it has no substitutions in it. Null where it
/// does, because an assignment whose value is a substitution is not read here
/// as one — it is a word like any other.
String? _plainOf(_Tok tok) {
  final pieces = tok.pieces!;
  if (pieces.any((piece) => piece is! String)) return null;
  return pieces.join();
}

/// Splits [source] into words and operators. Incomplete — an unterminated
/// quote, a `$( ` never closed — appends to [reasons] and stops: the caller
/// escalates rather than guessing what the rest meant.
List<_Tok> _tokenize(String source, List<String> reasons) {
  final tokens = <_Tok>[];
  var pieces = <Object>[];
  var wordOpen = false;

  void flush() {
    if (wordOpen) tokens.add(_Tok.word(pieces));
    pieces = <Object>[];
    wordOpen = false;
  }

  var i = 0;
  while (i < source.length) {
    final c = source[i];
    switch (c) {
      case " " || "\t" || "\n" || "\r":
        flush();
        i++;
      case ";" || "&" || "|" || "(" || ")":
        flush();
        final two = i + 1 < source.length ? source[i + 1] : "";
        if ((c == ";" || c == "&" || c == "|") && two == c) {
          tokens.add(_Tok.op(c + c));
          i += 2;
        } else if (c == "&" && two == ">") {
          tokens.add(_Tok.op(i + 2 < source.length && source[i + 2] == ">"
              ? "&>>"
              : "&>"));
          i += i + 2 < source.length && source[i + 2] == ">" ? 3 : 2;
        } else {
          tokens.add(_Tok.op(c));
          i++;
        }
      case ">":
        flush();
        if (i + 1 < source.length && source[i + 1] == ">") {
          tokens.add(_Tok.op(">>"));
          i += 2;
        } else if (i + 1 < source.length && source[i + 1] == "&") {
          tokens.add(_Tok.op(">&"));
          i += 2;
        } else {
          tokens.add(_Tok.op(">"));
          i++;
        }
      case "<":
        flush();
        if (i + 1 < source.length && source[i + 1] == "<") {
          tokens.add(_Tok.op(i + 2 < source.length && source[i + 2] == "<"
              ? "<<<"
              : "<<"));
          i += i + 2 < source.length && source[i + 2] == "<" ? 3 : 2;
        } else if (i + 1 < source.length && source[i + 1] == "&") {
          tokens.add(_Tok.op("<&"));
          i += 2;
        } else {
          tokens.add(_Tok.op("<"));
          i++;
        }
      case "\"":
        wordOpen = true;
        i++;
        while (i < source.length && source[i] != "\"") {
          if (source[i] == "\\" && i + 1 < source.length) {
            final next = source[i + 1];
            if (next == "\"" || next == "\\" || next == "\$" || next == "`") {
              pieces.add(next);
              i += 2;
              continue;
            }
          }
          if (source[i] == "\$") {
            final read = _readExpansion(source, i, reasons);
            if (read == null) return tokens;
            if (read.$1 is! String) pieces.add(read.$1);
            i = read.$2;
            continue;
          }
          pieces.add(source[i]);
          i++;
        }
        if (i >= source.length) {
          reasons.add("an unterminated double quote");
          return tokens;
        }
        i++;
      case "'":
        wordOpen = true;
        i++;
        final end = source.indexOf("'", i);
        if (end < 0) {
          reasons.add("an unterminated single quote");
          return tokens;
        }
        pieces.add(source.substring(i, end));
        i = end + 1;
      case "\$":
        final read = _readExpansion(source, i, reasons);
        if (read == null) return tokens;
        wordOpen = true;
        pieces.add(read.$1);
        i = read.$2;
      case "`":
        reasons.add("a backtick substitution");
        return tokens;
      case "#":
        if (!wordOpen) {
          final end = source.indexOf("\n", i);
          i = end < 0 ? source.length : end;
        } else {
          pieces.add(c);
          i++;
        }
      case "\\":
        if (i + 1 >= source.length) {
          reasons.add("a trailing backslash");
          return tokens;
        }
        wordOpen = true;
        pieces.add(source[i + 1]);
        i += 2;
      default:
        wordOpen = true;
        pieces.add(c);
        i++;
    }
  }
  flush();
  return tokens;
}

/// Reads one `$…` starting at [i] (where the `\$` is). Returns the piece —
/// a [String] for a plain expansion, a [_Substitution] for `$( … )` — and the
/// index past it. An expansion is carried as the name read, never as a value:
/// a parse that guesses values is a parse that lies.
(Object, int)? _readExpansion(String source, int i, List<String> reasons) {
  i++; // past '$'
  if (i >= source.length) return ("", i);
  final c = source[i];
  if (c == "(") {
    var depth = 0;
    final inner = StringBuffer();
    while (i < source.length) {
      final ch = source[i];
      if (ch == "(") depth++;
      if (ch == ")") {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
      inner.write(ch);
      i++;
    }
    if (depth != 0) {
      reasons.add("an unterminated \$( ) substitution");
      return null;
    }
    return (_Substitution(inner.toString()), i);
  }
  if (c == "{") {
    final end = source.indexOf("}", i);
    if (end < 0) {
      reasons.add("an unterminated \${ } expansion");
      return null;
    }
    final inner = source.substring(i + 1, end);
    // `${VAR:-word}` and friends: the word side is text the parse keeps, the
    // name is what it reads. Either way it is one opaque piece — no value is
    // resolved.
    return (_Expansion.text(inner), end + 1);
  }
  final rest = source.substring(i);
  final name = RegExp(r"^[A-Za-z_][A-Za-z0-9_]*|^[0-9@*#?$!_-]").firstMatch(rest);
  if (name == null) return ("", i + 1);
  return (
    _Expansion.text(source.substring(i, i + name.group(0)!.length)),
    i + name.group(0)!.length,
  );
}

/// A plain `$NAME` / `${…}` expansion, carried as its own text.
class _Expansion {
  const _Expansion.text(this.name);
  final String name;
}
