/// What a shell command parses to, decided before anything asks a model about
/// it. The approval regime reads command text, and a command's text can lie —
/// an `eval` built out of pieces, a redirect buried in a substitution — so the
/// deterministic layer answers for the commands it can model and refuses the
/// rest. The safe side is the deterministic side: a command whose write
/// behaviour this cannot answer for is not run, and the reason is worded so
/// the model can rewrite around it.
library;

import "../core/log.dart" show logFailure;

/// One command's parse. [isWindows] is the answer of a platform whose shell
/// this does not model: nothing is classified there statically, which is what
/// a driver without a parse owes the user (issue #248 carries the real one).
class ShellCommandAnalysis {
  ShellCommandAnalysis._({
    required this.modelable,
    required this.unmodelableReasons,
    required this.escalationReasons,
    required this.command,
    this._tokens = const [],
  });

  factory ShellCommandAnalysis.parse(String command, {bool isWindows = false}) {
    if (isWindows) {
      return ShellCommandAnalysis._(
        modelable: false,
        unmodelableReasons: const [
          "commands on this platform are not analyzed",
        ],
        escalationReasons: const [],
        command: command,
      );
    }

    try {
      return ShellCommandAnalysis._parse(command);
    } catch (e, trace) {
      // A bug in this parser must not take the turn down with it: a command
      // it cannot answer for is refused, which is the safe side.
      logFailure("shell", "command parse failed", "$e\n$trace");
      return ShellCommandAnalysis._(
        modelable: false,
        unmodelableReasons: ["the command parser failed on it ($e)"],
        escalationReasons: const [],
        command: command,
      );
    }
  }

  factory ShellCommandAnalysis._parse(String command) {
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
      tokens: tokens,
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
    final segmentAdvice = segments == null || segments.length < 2
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
  /// Computed on first read, from the parse's own tokens.
  List<String>? get modelableSegments {
    if (unmodelableReasons.isNotEmpty) return null;
    return _segments ??= _segmentsOf(command, _tokens);
  }

  /// The command the parse ran over, and its tokens, kept for the lazy split
  /// above.
  final String command;
  final List<_Tok> _tokens;
  List<String>? _segments;
}

/// Adds to [out] what in [parsed] an automatic decision cannot stand on, and
/// walks every substitution in its words as a command of its own — so `echo
/// $(cat ~/.ssh/id_ed25519)` is a read the parse can name, and a redirect or
/// assignment inside one counts too. [where] says where it was found. False
/// where a substitution does not tokenize; [reasons] then says why.
bool _escalate(
  _Pipeline parsed,
  List<String> out,
  List<String> reasons,
  String where,
) {
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
      if (!redirect.fdOnly) {
        out.add("cannot tell where the redirect$where writes");
      }
    } else if (target.any((piece) => piece is _Substitution)) {
      out.add(
        "redirects$where through a substitution, so the parse cannot "
        "name the file",
      );
    } else if (target.whereType<_Expansion>().firstOrNull case final e?) {
      // Where the file lands depends on the environment: the sandbox's
      // answer to make, not the parse's guess.
      out.add(
        "redirects$where through \$${e.name}, so the parse cannot "
        "name the file",
      );
    }
  }
  for (final word in parsed.words) {
    for (final piece in word.whereType<_Substitution>()) {
      final inner = _tokenize(piece.source, reasons);
      if (reasons.isNotEmpty ||
          !_escalate(
            _Pipeline._of(inner),
            out,
            reasons,
            " inside a substitution",
          )) {
        return false;
      }
    }
  }
  return true;
}

/// The top-level pieces [command] parses to: cut at the separators [tokens]
/// found outside a group, so a quote or a substitution stays in the segment
/// it belongs to. A here-document body is cut out of wherever it lies and put
/// back after the segment whose `<<` it feeds, so `cat <<EOF |` followed by a
/// body and `rm x` is `rm x` to a rule, not the body. For the refusal note
/// and per-segment rule matching.
List<String> _segmentsOf(String command, List<_Tok> tokens) {
  final texts = <String>[];
  final starts = <int>[];
  final bodies = <_Tok>[];
  var current = StringBuffer();
  var from = 0;
  var start = 0;
  var depth = 0;
  void cut(int end) {
    texts.add((current..write(command.substring(from, end))).toString().trim());
    starts.add(start);
    current = StringBuffer();
  }

  for (final tok in tokens) {
    switch (tok.kind) {
      case _TokKind.word:
        continue;
      case _TokKind.body:
        current.write(command.substring(from, tok.at));
        from = tok.end;
        bodies.add(tok);
      case _TokKind.op:
        switch (tok.text) {
          case "(":
            depth++;
          case ")":
            depth--;
          case "|" || "||" || "&&" || ";" || "&" || ";;" || "\n"
              when depth == 0:
            cut(tok.at);
            from = start = tok.end;
        }
    }
  }
  cut(command.length);
  for (final body in bodies) {
    final owner = starts.lastIndexWhere((at) => at <= body.owner);
    texts[owner] += command.substring(body.at, body.end);
  }
  return [
    for (final text in texts)
      if (text.isNotEmpty) text,
  ];
}

/// [segment] as the read-only tier reads it: its words in order, leading
/// assignments included, and the file each output redirect writes (null for
/// one with no target), the redirects' own syntax and any here-document body
/// left out of the words. Null where any of it is not plain text — an
/// expansion, a substitution, a group — or the segment does not tokenize,
/// the same answer the whole-command parse gives.
({List<String> words, List<String?> writes})? plainCommand(String segment) {
  final reasons = <String>[];
  final tokens = _tokenize(segment, reasons);
  if (reasons.isNotEmpty ||
      tokens.any(
        (t) => t.kind == _TokKind.op && (t.text == "(" || t.text == ")"),
      )) {
    return null;
  }
  final parsed = _Pipeline._of(tokens);
  final words = <String>[];
  for (final word in parsed.argv) {
    final text = _plain(word);
    if (text == null) return null;
    words.add(text);
  }
  final writes = <String?>[];
  for (final redirect in parsed.redirects) {
    final target = redirect.target == null ? null : _plain(redirect.target!);
    if (redirect.target != null && target == null) return null;
    if (!redirect.fromInput && !redirect.fdOnly) writes.add(target);
  }
  return (words: words, writes: writes);
}

/// The words of [segment] that stand where a command does: the first, and
/// the first after an operator, a reserved word (`{`, `then`, `do`, …), a
/// leading assignment or `command`/`builtin` — so `cd` is one in `{ cd x; }`
/// and not in `echo cd`. Null for one that is not plain text, whose command
/// nothing can name. As far as [segment] tokenizes.
List<String?> commandWords(String segment) {
  final commands = <String?>[];
  var head = true;
  var target = false;
  for (final tok in _tokenize(segment, <String>[])) {
    switch (tok.kind) {
      case _TokKind.body:
        break;
      case _TokKind.op:
        if (_redirectOps.contains(tok.text)) {
          target = true;
        } else {
          head = true;
        }
      case _TokKind.word:
        if (target) {
          target = false;
        } else if (head) {
          final text = _plainOf(tok);
          commands.add(text);
          head =
              text != null &&
              (_commandPrefixes.contains(text) || _isAssignmentWord(text));
        }
    }
  }
  return commands;
}

const _redirectOps = {">", ">>", "&>", "&>>", ">&", "<", "<<", "<<<", "<&"};

/// Words after which the next word is still the command.
const _commandPrefixes = {
  "{",
  "!",
  "if",
  "then",
  "elif",
  "else",
  "while",
  "until",
  "do",
  "time",
  "command",
  "builtin",
};

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
      case "<" || "<<" || "<<<" || ">&" || "<&":
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

enum _TokKind { word, op, body }

/// A word is a list of pieces: [String]s for the literal text and
/// [_Substitution]s where a `$( … )` was read. Operators are their own text.
/// A separator and a here-document body carry their span of the source, and
/// a body the offset of the `<<` it belongs to: [_segmentsOf] cuts by them.
class _Tok {
  const _Tok.op(this.text, [this.at = 0])
    : kind = _TokKind.op,
      end = at + text.length,
      owner = 0,
      pieces = null;
  const _Tok.word(this.pieces)
    : kind = _TokKind.word,
      text = "",
      at = 0,
      end = 0,
      owner = 0;
  const _Tok.body(this.at, this.end, this.owner)
    : kind = _TokKind.body,
      text = "",
      pieces = null;
  final _TokKind kind;
  final String text;
  final int at;
  final int end;
  final int owner;
  final List<Object>? pieces;
}

class _Substitution {
  const _Substitution(this.source);
  final String source;
}

/// One parsed pipeline: the commands a pipe/`;`/`&&`/`||` sequence separates,
/// their redirects and their leading assignments.
class _Pipeline {
  _Pipeline._(this.words, this.argv, this.redirects, this.assignments);

  factory _Pipeline._of(List<_Tok> tokens) {
    final words = <List<Object>>[];
    final argv = <List<Object>>[];
    final redirects = <_Redirect>[];
    final assignments = <String, String>{};
    var current = _Simple();
    var expectWord = false;

    void endCommand() {
      // A redirect the separator cut off before its target (`>|`, or a
      // here-document body full of `>` and `|`) keeps its null target, which
      // escalates; the next command's first word is not it.
      expectWord = false;
      if (current.words.isNotEmpty ||
          current.redirects.isNotEmpty ||
          current.assignments.isNotEmpty) {
        words.addAll(current.words);
        argv.addAll(current.argv);
        redirects.addAll(current.redirects);
        assignments.addAll(current.assignments);
        current = _Simple();
      }
    }

    for (final tok in tokens) {
      if (tok.kind == _TokKind.word) {
        if (expectWord) {
          final last = current.redirects.removeLast();
          // A duplication names a descriptor, or `-` to close one; anything
          // else after `>&` is a file it writes.
          final fdOnly =
              last.fdOnly && _descriptor.hasMatch(_plain(tok.pieces!) ?? "");
          current.redirects.add(_Redirect(tok.pieces!, last.fromInput, fdOnly));
          expectWord = false;
          continue;
        }
        current.argv.add(tok.pieces!);
        if (current.words.isEmpty &&
            current.redirects.isEmpty &&
            _isAssignmentWord(_plain(tok.pieces!) ?? "")) {
          final text = _plain(tok.pieces!)!;
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
            expectWord = true;
            current.redirects.add(_Redirect(null, false, true));
          case "<" || "<<" || "<<<":
            expectWord = true;
            current.redirects.add(_Redirect(null, true, false));
          case "<&":
            expectWord = true;
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
    return _Pipeline._(words, argv, redirects, assignments);
  }

  /// The command words, leading assignments taken out into [assignments].
  final List<List<Object>> words;

  /// Every word that is not a redirect's target, assignments included, in
  /// order: the command as the read-only tier reads it.
  final List<List<Object>> argv;
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
  final argv = <List<Object>>[];
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
String? _plainOf(_Tok tok) => _plain(tok.pieces!);

String? _plain(List<Object> pieces) =>
    pieces.every((piece) => piece is String) ? pieces.join() : null;

final _descriptor = RegExp(r"^(\d+|-)$");

/// Splits [source] into words and operators. Incomplete — an unterminated
/// quote, a `$( ` never closed — appends to [reasons] and stops: the caller
/// escalates rather than guessing what the rest meant.
///
/// A here-document's body is text, not shell: it is skipped, and only the
/// substitutions an unquoted delimiter leaves live in it come out, as a word
/// of the command it feeds, which ends after the body's closing line.
List<_Tok> _tokenize(String source, List<String> reasons) {
  final tokens = <_Tok>[];
  var pieces = <Object>[];
  var wordOpen = false;
  var quoted = false;
  // Set by `<<`: the next word is a delimiter, its body read at the newline.
  var delimiterNext = false;
  var delimiterAt = 0;
  var dash = false;
  final pending = <_Heredoc>[];

  // `2>`: the descriptor written against a redirect is the redirect's, not a
  // word of the command.
  void dropDescriptor() {
    if (wordOpen &&
        !quoted &&
        RegExp(r"^\d+$").hasMatch(_plain(pieces) ?? "")) {
      pieces = <Object>[];
      wordOpen = false;
    }
  }

  void flush() {
    if (wordOpen) {
      final word = _Tok.word(pieces);
      tokens.add(word);
      if (delimiterNext) {
        delimiterNext = false;
        final delimiter = _plainOf(word);
        if (delimiter == null) {
          reasons.add("a here-document delimiter with an expansion in it");
        }
        pending.add(
          _Heredoc(
            delimiter ?? "",
            at: delimiterAt,
            quoted: quoted,
            dash: dash,
          ),
        );
      }
    }
    pieces = <Object>[];
    wordOpen = false;
    quoted = false;
  }

  var i = 0;
  while (i < source.length) {
    final c = source[i];
    switch (c) {
      case " " || "\t" || "\r":
        flush();
        i++;
      case "\n":
        flush();
        if (delimiterNext) {
          reasons.add("a here-document with no delimiter");
          return tokens;
        }
        // After an operator that wants more, or before anything, a newline is
        // a line break rather than the end of a command.
        final last = tokens.lastOrNull;
        final carriesOn =
            last == null ||
            (last.kind == _TokKind.op && _carriesOn.contains(last.text));
        var end = i;
        if (pending.isNotEmpty) {
          final read = _readBodies(source, i + 1, pending, tokens, reasons);
          if (read == null) return tokens;
          pending.clear();
          end = read;
        }
        if (!carriesOn && end < source.length) tokens.add(_Tok.op("\n", end));
        i = end + 1;
      case ";" || "&" || "|" || "(" || ")":
        flush();
        final two = i + 1 < source.length ? source[i + 1] : "";
        if ((c == ";" || c == "&" || c == "|") && two == c) {
          tokens.add(_Tok.op(c + c, i));
          i += 2;
        } else if (c == "&" && two == ">") {
          tokens.add(
            _Tok.op(
              i + 2 < source.length && source[i + 2] == ">" ? "&>>" : "&>",
            ),
          );
          i += i + 2 < source.length && source[i + 2] == ">" ? 3 : 2;
        } else {
          tokens.add(_Tok.op(c, i));
          i++;
        }
      case ">":
        dropDescriptor();
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
        dropDescriptor();
        flush();
        final two = i + 1 < source.length ? source[i + 1] : "";
        final three = i + 2 < source.length ? source[i + 2] : "";
        if (two == "<" && three == "<") {
          tokens.add(const _Tok.op("<<<"));
          i += 3;
        } else if (two == "<") {
          tokens.add(const _Tok.op("<<"));
          delimiterNext = true;
          delimiterAt = i;
          // `<<-` strips leading tabs from the body and its closing line.
          dash = three == "-";
          i += dash ? 3 : 2;
        } else if (two == "&") {
          tokens.add(_Tok.op("<&"));
          i += 2;
        } else {
          tokens.add(_Tok.op("<"));
          i++;
        }
      case "\"":
        wordOpen = true;
        quoted = true;
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
        quoted = true;
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
        // A line continuation joins the lines; it is no character at all.
        if (source[i + 1] != "\n") {
          wordOpen = true;
          quoted = true;
          pieces.add(source[i + 1]);
        }
        i += 2;
      default:
        wordOpen = true;
        pieces.add(c);
        i++;
    }
  }
  flush();
  if (delimiterNext || pending.isNotEmpty) {
    reasons.add("a here-document with no closing delimiter");
  }
  return tokens;
}

/// What a newline after them continues rather than ends.
const _carriesOn = {"|", "||", "&&", ";", "&", ";;", "(", "\n"};

class _Heredoc {
  const _Heredoc(
    this.delimiter, {
    required this.at,
    required this.quoted,
    required this.dash,
  });
  final String delimiter;

  /// Where its `<<` is, which decides the segment the body goes back on.
  final int at;

  /// A quoted delimiter leaves the body inert; an unquoted one still runs the
  /// substitutions in it.
  final bool quoted;
  final bool dash;
}

/// Reads the bodies of [pending], in order, starting at [i]: the line after
/// the one that named them. Returns the end of the last closing line, or null
/// where one never closes. Each body goes into [tokens] as its span, from the
/// newline before it to the end of its closing line; an unquoted body's
/// substitutions follow it as one word, so the parse walks them like any
/// other.
int? _readBodies(
  String source,
  int i,
  List<_Heredoc> pending,
  List<_Tok> tokens,
  List<String> reasons,
) {
  for (final doc in pending) {
    final start = i;
    int? bodyEnd;
    while (bodyEnd == null && i < source.length) {
      final newline = source.indexOf("\n", i);
      final lineEnd = newline < 0 ? source.length : newline;
      var from = i;
      while (doc.dash && from < lineEnd && source[from] == "\t") {
        from++;
      }
      if (lineEnd - from == doc.delimiter.length &&
          source.startsWith(doc.delimiter, from)) {
        bodyEnd = i;
      }
      i = lineEnd + 1;
    }
    if (bodyEnd == null) {
      reasons.add("a here-document with no closing ${doc.delimiter}");
      return null;
    }
    tokens.add(_Tok.body(start - 1, i - 1, doc.at));
    if (doc.quoted) continue;
    final body = source.substring(start, bodyEnd);
    final live = <Object>[];
    for (var j = 0; j < body.length;) {
      switch (body[j]) {
        case "\\":
          j += 2;
        case "`":
          reasons.add("a backtick substitution");
          return null;
        case "\$":
          final read = _readExpansion(body, j, reasons);
          if (read == null) return null;
          if (read.$1 is _Substitution) live.add(read.$1);
          j = read.$2;
        default:
          j++;
      }
    }
    if (live.isNotEmpty) tokens.add(_Tok.word(live));
  }
  return i - 1;
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
  final name = _expansionName.matchAsPrefix(source, i);
  if (name == null) return ("", i + 1);
  return (_Expansion.text(name.group(0)!), name.end);
}

final _expansionName = RegExp(r"[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!_-]");

/// A plain `$NAME` / `${…}` expansion, carried as its own text.
class _Expansion {
  const _Expansion.text(this.name);
  final String name;
}
