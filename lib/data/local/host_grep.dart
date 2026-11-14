import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;

/// A guest directory that is a host one: what the guest calls [guest] is
/// [host] on the host's disk.
typedef GuestMount = ({String guest, String host});

/// [guest], a normalized absolute guest path, on the host; null where it is
/// not under one of [mounts], the longest winning as the guest's lookup does.
String? hostPathOf(List<GuestMount> mounts, String guest) {
  GuestMount? best;
  for (final mount in mounts) {
    if (guest == mount.guest || p.posix.isWithin(mount.guest, guest)) {
      if (best == null || mount.guest.length > best.guest.length) best = mount;
    }
  }
  if (best == null) return null;
  final relative = p.posix.relative(guest, from: best.guest);
  return relative == "." ? best.host : p.join(best.host, relative);
}

/// The guest's busybox `grep -r`, run on the host's files; see "Tools the
/// host runs" in ios/AGENTS.md. A port of busybox 1.37's `grep_file` and
/// `recursive_action`, so what it prints is theirs byte for byte; anything it
/// cannot be sure of answering the same way is [GrepJob.parse] answering
/// null or [GrepJob.run] answering null, and the guest's grep runs instead.
class GrepJob {
  GrepJob._(
    this._patterns, {
    required this.cwd,
    required this.mounts,
    required this.operands,
    required this.opts,
    required this.maxMatches,
    required this.linesBefore,
    required this.linesAfter,
  });

  final String cwd;
  final List<GuestMount> mounts;
  final List<String> operands;
  final List<_Matcher> _patterns;
  final Set<String> opts;
  final int maxMatches;
  final int linesBefore;
  final int linesAfter;

  /// Past this much output the guest's grep prints it instead: the answer is
  /// held whole in memory and in the response file.
  static const maxOutput = 32 << 20;

  /// busybox grep's arguments, or null where they are not a recursive search
  /// this answers: no `-r`/`-R`, stdin, `-o`, `-f`, a long option but
  /// `--color`, or a pattern the translation refuses.
  static GrepJob? parse(
    String cwd,
    List<String> args,
    List<GuestMount> mounts,
  ) {
    final opts = <String>{};
    final patternArgs = <String>[];
    final operands = <String>[];
    int? max, after, before, context;
    var endOfOptions = false;
    int? number(String? v) =>
        v != null && RegExp(r"^[0-9]{1,9}$").hasMatch(v) ? int.parse(v) : null;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (endOfOptions || arg == "-" || !arg.startsWith("-")) {
        operands.add(arg);
        continue;
      }
      if (arg == "--") {
        endOfOptions = true;
        continue;
      }
      if (arg.startsWith("--")) {
        // busybox takes --color and ignores it; any other is its error.
        if (arg == "--color" || arg.startsWith("--color=")) continue;
        return null;
      }
      for (var j = 1; j < arg.length; j++) {
        final c = arg[j];
        if ("emABC".contains(c)) {
          final value = j + 1 < arg.length
              ? arg.substring(j + 1)
              : (++i < args.length ? args[i] : null);
          if (value == null) return null;
          if (c == "e") {
            patternArgs.add(value);
            opts.add("e");
          } else {
            final n = number(value);
            if (n == null) return null;
            switch (c) {
              case "m":
                max = n;
                opts.add("m");
              case "A":
                after = n;
                opts.add("A");
              case "B":
                before = n;
                opts.add("B");
              case "C":
                // -C unsets an -A or -B before it; one after it overrides.
                context = n;
                opts
                  ..add("C")
                  ..remove("A")
                  ..remove("B");
            }
          }
          break;
        }
        if (!"lnqvscFiHhLrRwxEaI".contains(c)) return null;
        opts.add(c);
        // -H unsets an -h before it.
        if (c == "H") opts.remove("h");
      }
    }
    if (!opts.contains("r") && !opts.contains("R")) return null;
    if (!opts.contains("e")) {
      if (operands.isEmpty) return null;
      patternArgs.add(operands.removeAt(0));
    }
    // No operand is stdin, which is not the host's.
    if (operands.isEmpty || operands.contains("-")) return null;
    var linesAfter = after ?? 0;
    var linesBefore = before ?? 0;
    if (context != null) {
      if (!opts.contains("A")) linesAfter = context;
      if (!opts.contains("B")) linesBefore = context;
    }
    if (opts.intersection({"c", "q", "l", "L"}).isNotEmpty) {
      opts.remove("n");
      linesBefore = 0;
      linesAfter = 0;
    }
    final fixed = opts.contains("F");
    final icase = opts.contains("i");
    final patterns = <_Matcher>[];
    for (final arg in patternArgs) {
      for (final pattern in arg.split("\n")) {
        final matcher = fixed
            ? _FixedMatcher.of(pattern, opts)
            : _RegexMatcher.of(pattern, opts, icase: icase);
        if (matcher == null) return null;
        patterns.add(matcher);
      }
    }
    return GrepJob._(
      patterns,
      cwd: cwd,
      mounts: mounts,
      operands: operands,
      opts: opts,
      maxMatches: max ?? 0,
      linesBefore: linesBefore,
      linesAfter: linesAfter,
    );
  }

  /// [args] parsed and run, or null for the guest's grep. Both on the
  /// caller's isolate: a RegExp does not cross to another.
  static ({int code, Uint8List output})? search(
    String cwd,
    List<String> args,
    List<GuestMount> mounts,
  ) => parse(cwd, args, mounts)?.run();

  bool has(String opt) => opts.contains(opt);

  final _out = BytesBuilder(copy: false);
  var _printFilename = false;
  var _didPrintLine = false;
  var _lastLinePrinted = 0;
  late final List<Uint8List?> _beforeBuf = List.filled(linesBefore, null);

  /// The exit code and output, or null for the guest's grep: an error it
  /// would print, a file it would block on, or a line it might match
  /// differently.
  ({int code, Uint8List output})? run() {
    try {
      return _run();
    } on _Fallback {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  ({int code, Uint8List output}) _run() {
    for (final operand in operands) {
      final guest = p.posix.normalize(p.posix.join(cwd, operand));
      // A mount inside the tree that is not where the host's tree has it
      // would be walked past.
      for (final mount in mounts) {
        if (!p.posix.isWithin(guest, mount.guest)) continue;
        final host = hostPathOf(mounts, guest);
        final natural = host == null
            ? null
            : p.join(host, p.posix.relative(mount.guest, from: guest));
        if (natural != mount.host) throw const _Fallback();
      }
    }
    _printFilename = operands.length > 1;
    if (has("H")) _printFilename = true;
    if (has("h")) _printFilename = false;
    var matched = false;
    try {
      for (final operand in operands) {
        final guest = p.posix.normalize(p.posix.join(cwd, operand));
        final resolved = _resolve(guest);
        final type = FileSystemEntity.typeSync(resolved.host);
        if (type == FileSystemEntityType.directory) {
          if (!has("h")) _printFilename = true;
          matched |= _walk(guest, operand, 0);
          continue;
        }
        if (type != FileSystemEntityType.file) throw const _Fallback();
        matched |= _grepFile(resolved.host, operand);
      }
    } on _Quit {
      return (code: 0, output: _out.takeBytes());
    }
    return (code: matched ? 0 : 1, output: _out.takeBytes());
  }

  /// `recursive_action1`: [guest] is the entry, [display] the path grep
  /// prints for it. Symlinks are followed at the top and, with `-R`,
  /// everywhere.
  bool _walk(String guest, String display, int depth) {
    if (depth > 64) throw const _Fallback();
    final follow = depth == 0 || has("R");
    final ({String guest, String host}) at;
    if (follow) {
      at = _resolve(guest);
    } else {
      // The parent is resolved already, so the entry is where the host has
      // it.
      final host = hostPathOf(mounts, guest);
      if (host == null) throw const _Fallback();
      at = (guest: guest, host: host);
    }
    final type = FileSystemEntity.typeSync(at.host, followLinks: false);
    if (type == FileSystemEntityType.link) {
      // Only an entry not followed: `file_action_grep` skips one to a
      // directory and reads one to a file.
      final target = _resolve(guest);
      final targetType = FileSystemEntity.typeSync(target.host);
      if (targetType == FileSystemEntityType.directory) return false;
      if (targetType != FileSystemEntityType.file) throw const _Fallback();
      return _grepFile(target.host, display);
    }
    if (type == FileSystemEntityType.file) return _grepFile(at.host, display);
    if (type != FileSystemEntityType.directory) throw const _Fallback();
    var matched = false;
    // listSync is readdir's order, which is the guest's: its realfs reads
    // the same directory.
    for (final entry in Directory(at.host).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final childDisplay = display.endsWith("/")
          ? "$display$name"
          : "$display/$name";
      matched |= _walk(p.posix.join(at.guest, name), childDisplay, depth + 1);
    }
    return matched;
  }

  /// [guest] with every symlink in it followed the way the guest follows
  /// it, and where that is on the host. A link out of the host-backed
  /// directories is the fakefs's to answer.
  ({String guest, String host}) _resolve(String guest) {
    final pending = p.posix.split(guest)..removeAt(0);
    var resolved = "/";
    var hops = 0;
    while (pending.isNotEmpty) {
      final part = pending.removeAt(0);
      if (part == "." || part.isEmpty) continue;
      if (part == "..") {
        resolved = p.posix.dirname(resolved);
        continue;
      }
      final next = p.posix.join(resolved, part);
      final host = hostPathOf(mounts, next);
      if (host == null) {
        // An ancestor of a mount is a directory the fakefs holds, and is
        // passed through; anything else is not ours.
        if (mounts.any((m) => p.posix.isWithin(next, m.guest))) {
          resolved = next;
          continue;
        }
        throw const _Fallback();
      }
      if (FileSystemEntity.isLinkSync(host)) {
        if (++hops > 40) throw const _Fallback();
        final target = Link(host).targetSync();
        final parts = p.posix.split(target);
        if (p.posix.isAbsolute(target)) {
          resolved = "/";
          parts.removeAt(0);
        }
        pending.insertAll(0, parts);
        continue;
      }
      resolved = next;
    }
    final host = hostPathOf(mounts, resolved);
    if (host == null) throw const _Fallback();
    return (guest: resolved, host: host);
  }

  /// `grep_file`, over [path]'s lines as busybox reads them: a line ends at
  /// a newline, which is dropped, or at a NUL.
  bool _grepFile(String path, String curFile) {
    final data = File(path).readAsBytesSync();
    var linenum = 0;
    var nmatches = 0;
    var printAfter = 0;
    var curpos = 0;
    final invert = has("v");
    var start = 0;
    while (start < data.length) {
      var end = start;
      while (end < data.length && data[end] != 0x0a && data[end] != 0) {
        end++;
      }
      final line = Uint8List.sublistView(data, start, end);
      start = end + 1;
      linenum++;
      var found = false;
      for (final pattern in _patterns) {
        final hit = pattern.matches(line);
        if (hit == null) throw const _Fallback();
        if (hit) {
          found = true;
          break;
        }
      }
      if (found != invert) {
        nmatches++;
        if (has("q") || has("l") || has("L")) {
          if (has("q")) throw const _Quit();
          if (has("l")) {
            _puts(curFile);
            return true;
          }
          return false;
        }
        if (has("m") && nmatches > maxMatches) break;
        if (!has("c")) {
          final prevpos = curpos == 0 ? linesBefore - 1 : curpos - 1;
          if (linesBefore > 0 && _beforeBuf[prevpos] != null) {
            var first = linenum - linesBefore;
            var idx = curpos;
            while (_beforeBuf[idx] == null) {
              idx = (idx + 1) % linesBefore;
              first++;
            }
            while (_beforeBuf[idx] != null) {
              _printLine(_beforeBuf[idx]!, first, curFile, "-");
              _beforeBuf[idx] = null;
              idx = (idx + 1) % linesBefore;
              first++;
            }
          }
          printAfter = linesAfter;
          _printLine(line, linenum, curFile, ":");
        }
      } else if (printAfter > 0) {
        _printLine(line, linenum, curFile, "-");
        printAfter--;
      } else if (linesBefore > 0) {
        _beforeBuf[curpos] = line;
        curpos = (curpos + 1) % linesBefore;
      }
      if (has("m") && printAfter == 0 && nmatches == maxMatches) break;
    }
    if (has("c")) {
      if (_printFilename) _write("$curFile:");
      _write("$nmatches\n");
    }
    if (has("L")) {
      _puts(curFile);
      return true;
    }
    return nmatches != 0;
  }

  void _printLine(Uint8List line, int linenum, String curFile, String deco) {
    if (linenum < 1) return;
    if ((linesBefore > 0 || linesAfter > 0) &&
        _didPrintLine &&
        _lastLinePrinted != linenum - 1) {
      _write("--\n");
    }
    _didPrintLine = true;
    _lastLinePrinted = linenum;
    if (_printFilename) _write("$curFile$deco");
    if (has("n")) _write("$linenum$deco");
    _out
      ..add(line)
      ..addByte(0x0a);
    if (_out.length > maxOutput) throw const _Fallback();
  }

  void _puts(String text) => _write("$text\n");

  void _write(String text) => _out.add(utf8.encode(text));
}

class _Fallback implements Exception {
  const _Fallback();
}

/// `-q`'s exit at the first match.
class _Quit implements Exception {
  const _Quit();
}

sealed class _Matcher {
  /// Whether [line] holds this pattern; null where the guest might answer
  /// otherwise.
  bool? matches(Uint8List line);
}

/// `-F`: strstr, or musl's ASCII-only strcasestr, on the bytes.
class _FixedMatcher extends _Matcher {
  _FixedMatcher(this.needle, this.opts);

  final Uint8List needle;
  final Set<String> opts;

  static _FixedMatcher? of(String pattern, Set<String> opts) {
    // An empty word reads past the line in busybox.
    if (pattern.isEmpty && opts.contains("w")) return null;
    return _FixedMatcher(utf8.encode(pattern), opts);
  }

  @override
  bool matches(Uint8List line) {
    final icase = opts.contains("i");
    var str = 0;
    while (true) {
      final match = icase ? _strcasestr(line, str) : _strstr(line, str);
      if (match < 0) return false;
      if (opts.contains("x")) {
        return match == str && match + needle.length == line.length;
      }
      if (!opts.contains("w")) return true;
      var c = match != 0 ? line[match - 1] : 0x20;
      if (!_isWord(c)) {
        final after = match + needle.length;
        c = after < line.length ? line[after] : 0;
        if (c == 0 || !_isWord(c)) return true;
      }
      str = match + 1;
    }
  }

  int _strstr(Uint8List h, int from) {
    for (var i = from; i + needle.length <= h.length; i++) {
      if (_at(h, i, (a, b) => a == b)) return i;
    }
    return -1;
  }

  /// musl's: no match in an empty haystack, even of an empty needle.
  int _strcasestr(Uint8List h, int from) {
    for (var i = from; i < h.length; i++) {
      if (i + needle.length <= h.length &&
          _at(h, i, (a, b) => _lower(a) == _lower(b))) {
        return i;
      }
    }
    return -1;
  }

  bool _at(Uint8List h, int i, bool Function(int, int) same) {
    for (var j = 0; j < needle.length; j++) {
      if (!same(h[i + j], needle[j])) return false;
    }
    return true;
  }
}

int _lower(int c) => c >= 0x41 && c <= 0x5a ? c + 32 : c;

/// musl's isalnum or `_`, which is ASCII alone.
bool _isWord(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f;

/// A POSIX pattern, translated into a Dart one that matches the same lines
/// as musl's regexec in its UTF-8 locale.
class _RegexMatcher extends _Matcher {
  _RegexMatcher(this.regex, this.shape, this.opts);

  final RegExp regex;
  final _Shape shape;
  final Set<String> opts;

  static _RegexMatcher? of(
    String pattern,
    Set<String> opts, {
    required bool icase,
  }) {
    final shape = _Translator(
      pattern,
      extended: opts.contains("E"),
      icase: icase,
    ).translate();
    if (shape == null) return null;
    // -w takes the match regexec answers, leftmost-longest, which is only
    // the leftmost-first one Dart answers where there is one way to match.
    if (opts.contains("w") && (!shape.literal || shape.nullable)) return null;
    final source = opts.contains("x") ? "^(?:${shape.source})\$" : shape.source;
    return _RegexMatcher(
      RegExp(source, unicode: true, dotAll: true),
      shape,
      opts,
    );
  }

  @override
  bool? matches(Uint8List line) {
    final invalid = _firstInvalid(line);
    // Classes and case are musl's tables past ASCII: a line is ours only
    // where each of its other characters is surely outside them.
    if (shape.tables.isNotEmpty && line.any((b) => b >= 0x80)) {
      for (final c in utf8.decode(line, allowMalformed: true).runes) {
        if (c >= 0x80 && !shape.tables.every((t) => t.surelyOutside(c))) {
          return null;
        }
      }
    }
    if (invalid < 0) {
      final text = utf8.decode(line);
      if (opts.contains("w")) return _word(text);
      return regex.hasMatch(text);
    }
    // regexec gives up at the first invalid sequence it reads, and reads one
    // character past the earliest end of a match; that is only this simple
    // where nothing looks past a match and none is empty.
    if (opts.contains("w") ||
        opts.contains("x") ||
        shape.lookahead ||
        shape.nullable) {
      return null;
    }
    final chars = utf8.decode(Uint8List.sublistView(line, 0, invalid)).runes;
    if (chars.isEmpty) return false;
    return regex.hasMatch(String.fromCharCodes(chars.take(chars.length - 1)));
  }

  /// busybox's -w: a match with a word character beside it is retried past
  /// its end.
  bool _word(String text) {
    var from = 0;
    while (from <= text.length) {
      final next = regex.allMatches(text, from).iterator;
      if (!next.moveNext()) return false;
      final m = next.current;
      final before = m.start > 0 ? text.codeUnitAt(m.start - 1) : 0x20;
      final after = m.end < text.length ? text.codeUnitAt(m.end) : 0;
      if (!_isWord(before) && !_isWord(after)) return true;
      if (m.end == 0) return false;
      from = m.end;
    }
    return false;
  }
}

/// The offset of the first byte that does not start a valid UTF-8 sequence
/// as musl's mbtowc reads one, or -1.
int _firstInvalid(Uint8List b) {
  var i = 0;
  while (i < b.length) {
    final c = b[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    int n, min;
    if (c >= 0xc2 && c <= 0xdf) {
      n = 1;
      min = 0x80;
    } else if (c >= 0xe0 && c <= 0xef) {
      n = 2;
      min = 0x800;
    } else if (c >= 0xf0 && c <= 0xf4) {
      n = 3;
      min = 0x10000;
    } else {
      return i;
    }
    var cp = c & (0x3f >> n);
    for (var j = 1; j <= n; j++) {
      if (i + j >= b.length) return i;
      final cc = b[i + j];
      if (cc & 0xc0 != 0x80) return i;
      cp = (cp << 6) | (cc & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return i;
    i += n + 1;
  }
  return -1;
}

/// What a translated pattern is.
class _Shape {
  const _Shape({
    required this.source,
    required this.nullable,
    required this.literal,
    required this.tables,
    required this.lookahead,
  });

  final String source;

  /// Can match the empty string.
  final bool nullable;

  /// Characters alone: one way to match where it matches.
  final bool literal;

  /// The musl tables it reads, which past ASCII are not this file's.
  final Set<_Table> tables;

  /// Asserts something about the character after a position: `$`, `\b`,
  /// `\<`, `\>`.
  final bool lookahead;
}

/// POSIX BRE or ERE, as musl's TRE parses it, into a Dart `unicode` regex;
/// null for anything outside the subset whose meaning is certain.
class _Translator {
  _Translator(String pattern, {required this.extended, required this.icase})
    : _p = pattern.runes.toList();

  final List<int> _p;
  final bool extended;
  final bool icase;
  var _i = 0;
  var _literal = true;
  final _tables = <_Table>{};
  var _lookahead = false;

  _Shape? translate() {
    try {
      final alt = _alternation(0);
      if (_i != _p.length) return null;
      return _Shape(
        source: alt.source,
        nullable: alt.nullable,
        literal: _literal,
        tables: _tables,
        lookahead: _lookahead,
      );
    } on _Refused {
      return null;
    }
  }

  bool get _end => _i >= _p.length;
  int get _c => _p[_i];
  bool _at(String s) {
    final r = s.runes.toList();
    if (_i + r.length > _p.length) return false;
    for (var j = 0; j < r.length; j++) {
      if (_p[_i + j] != r[j]) return false;
    }
    return true;
  }

  bool get _atBar => extended ? _at("|") : _at(r"\|");
  bool get _atClose => extended ? _at(")") : _at(r"\)");

  ({String source, bool nullable}) _alternation(int depth) {
    final branches = <({String source, bool nullable})>[_branch(depth)];
    while (!_end && _atBar) {
      _i += extended ? 1 : 2;
      _literal = false;
      branches.add(_branch(depth));
    }
    if (branches.length == 1) return branches.single;
    return (
      source: branches.map((b) => b.source).join("|"),
      nullable: branches.any((b) => b.nullable),
    );
  }

  ({String source, bool nullable}) _branch(int depth) {
    final out = StringBuffer();
    var nullable = true;
    var first = true;
    while (!_end && !_atBar && !(depth > 0 && _atClose)) {
      final piece = _piece(depth, first: first);
      out.write(piece.source);
      nullable &= piece.nullable;
      first = false;
    }
    // An empty branch or group is TRE's to make sense of.
    if (first) throw const _Refused();
    return (source: out.toString(), nullable: nullable);
  }

  ({String source, bool nullable}) _piece(int depth, {required bool first}) {
    final atom = _atom(depth, first: first);
    final quantified = _quantifier();
    if (quantified == null) {
      return (source: atom.source, nullable: atom.nullable);
    }
    _literal = false;
    if (atom.anchor) throw const _Refused();
    // A second quantifier on the first is TRE's.
    if (_quantifierAhead) throw const _Refused();
    return (
      source: "(?:${atom.source})${quantified.source}",
      nullable: atom.nullable || quantified.min == 0,
    );
  }

  bool get _quantifierAhead {
    if (_end) return false;
    if (_at("*")) return true;
    return extended
        ? _at("+") || _at("?") || _at("{")
        : _at(r"\+") || _at(r"\?") || _at(r"\{");
  }

  ({String source, int min})? _quantifier() {
    if (_end) return null;
    if (_at("*")) {
      _i++;
      return (source: "*", min: 0);
    }
    if (extended ? _at("+") : _at(r"\+")) {
      _i += extended ? 1 : 2;
      return (source: "+", min: 1);
    }
    if (extended ? _at("?") : _at(r"\?")) {
      _i += extended ? 1 : 2;
      return (source: "?", min: 0);
    }
    if (extended ? _at("{") : _at(r"\{")) {
      _i += extended ? 1 : 2;
      final m = _digits();
      int? n = m;
      var open = false;
      if (!_end && _at(",")) {
        _i++;
        open = true;
        n = _end || !_isDigit(_c) ? null : _digits();
      }
      if (!(extended ? _at("}") : _at(r"\}"))) throw const _Refused();
      _i += extended ? 1 : 2;
      if (m > 255 || (n != null && (n > 255 || n < m))) {
        throw const _Refused();
      }
      final source = !open ? "{$m}" : (n == null ? "{$m,}" : "{$m,$n}");
      return (source: source, min: m);
    }
    return null;
  }

  int _digits() {
    if (_end || !_isDigit(_c)) throw const _Refused();
    var n = 0;
    while (!_end && _isDigit(_c)) {
      n = n * 10 + _c - 0x30;
      if (n > 1000) throw const _Refused();
      _i++;
    }
    return n;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  ({String source, bool nullable, bool anchor}) _atom(
    int depth, {
    required bool first,
  }) {
    final c = _c;
    if (extended ? c == 0x28 : _at(r"\(")) {
      _i += extended ? 1 : 2;
      _literal = false;
      final inner = _alternation(depth + 1);
      if (!_atClose) throw const _Refused();
      _i += extended ? 1 : 2;
      return (
        source: "(?:${inner.source})",
        nullable: inner.nullable,
        anchor: false,
      );
    }
    if (c == 0x5e) {
      // BRE's ^ is an anchor only where a branch starts.
      if (!extended && !first) throw const _Refused();
      _i++;
      _literal = false;
      return (source: "^", nullable: true, anchor: true);
    }
    if (c == 0x24) {
      _i++;
      // BRE's $ is an anchor only where a branch ends.
      if (!extended && !(_end || _atBar || (depth > 0 && _atClose))) {
        throw const _Refused();
      }
      _literal = false;
      _lookahead = true;
      return (source: r"$", nullable: true, anchor: true);
    }
    if (c == 0x2a || (extended && (c == 0x2b || c == 0x3f || c == 0x7b))) {
      // A quantifier with nothing to quantify.
      throw const _Refused();
    }
    if (extended && (c == 0x29 || c == 0x7d || c == 0x7c)) {
      throw const _Refused();
    }
    if (c == 0x2e) {
      _i++;
      _literal = false;
      return (source: ".", nullable: false, anchor: false);
    }
    if (c == 0x5b) {
      _i++;
      _literal = false;
      return (source: _bracket(), nullable: false, anchor: false);
    }
    if (c == 0x5c) {
      if (_i + 1 >= _p.length) throw const _Refused();
      final e = _p[_i + 1];
      _i += 2;
      return _escape(e);
    }
    _i++;
    return (source: _char(c), nullable: false, anchor: false);
  }

  ({String source, bool nullable, bool anchor}) _escape(int e) {
    const classes = {
      0x77: (r"[A-Za-z0-9_]", _Table.word), // w
      0x57: (r"[^A-Za-z0-9_]", _Table.word), // W
      0x73: (r"[ \t\n\v\f\r]", _Table.space), // s
      0x53: (r"[^ \t\n\v\f\r]", _Table.space), // S
      0x64: (r"[0-9]", null), // d
      0x44: (r"[^0-9]", null), // D
    };
    if (classes[e] case (final source, final table)) {
      _literal = false;
      _uses(table);
      return (source: source, nullable: false, anchor: false);
    }
    final assertion = switch (e) {
      0x62 => r"\b", // b
      0x3c => r"(?<![A-Za-z0-9_])(?=[A-Za-z0-9_])", // <
      0x3e => r"(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])", // >
      _ => null,
    };
    if (assertion != null) {
      _literal = false;
      _uses(_Table.word);
      _lookahead = true;
      return (source: assertion, nullable: true, anchor: true);
    }
    // Letters and digits are TRE's macros, back references or its errors;
    // the rest are themselves.
    if (e >= 0x80 || _isDigit(e) || _isAlpha(e)) throw const _Refused();
    if (!extended && "(){}|+?".runes.contains(e)) throw const _Refused();
    return (source: _char(e), nullable: false, anchor: false);
  }

  static bool _isAlpha(int c) =>
      (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

  /// A literal character, both cases of it under -i: TRE's REG_ICASE
  /// matches a letter's toupper and tolower and nothing else.
  String _char(int c) {
    if (icase && c >= 0x80) throw const _Refused();
    if (icase && _isAlpha(c)) {
      final lower = c | 0x20;
      return "[${String.fromCharCode(lower - 32)}${String.fromCharCode(lower)}]";
    }
    return _escaped(c);
  }

  /// Under -i a class is asked of the input's other case too.
  void _uses(_Table? table) {
    if (table == null) return;
    _tables.add(table);
    if (icase) _tables.add(_Table.caseMap);
  }

  static String _escaped(int c) => _isAlpha(c) || _isDigit(c) || c == 0x5f
      ? String.fromCharCode(c)
      : "\\u{${c.toRadixString(16)}}";

  /// After the `[`, through the `]`: the set's ASCII members worked out
  /// here, so the Dart class is plain ranges whatever POSIX said.
  String _bracket() {
    var negate = false;
    if (!_end && _c == 0x5e) {
      negate = true;
      _i++;
    }
    final members = List.filled(128, false);
    var first = true;
    while (true) {
      if (_end) throw const _Refused();
      final c = _c;
      if (c == 0x5d && !first) {
        _i++;
        break;
      }
      first = false;
      if (c == 0x5b && _i + 1 < _p.length) {
        final next = _p[_i + 1];
        if (next == 0x2e || next == 0x3d) throw const _Refused();
        if (next == 0x3a) {
          final close = _indexOf(":]", _i + 2);
          if (close < 0) throw const _Refused();
          final name = String.fromCharCodes(_p.sublist(_i + 2, close));
          final (cls, table) = _posixClass(name);
          _uses(table);
          for (var x = 0; x < 128; x++) {
            if (cls(x) || (icase && (cls(_lower(x)) || cls(_upper(x))))) {
              members[x] = true;
            }
          }
          _i = close + 2;
          continue;
        }
      }
      if (c >= 0x80) throw const _Refused();
      _i++;
      var hi = c;
      if (!_end && _c == 0x2d && _i + 1 < _p.length && _p[_i + 1] != 0x5d) {
        hi = _p[_i + 1];
        if (hi >= 0x80 || hi == 0x5b || hi < c) throw const _Refused();
        _i += 2;
      }
      for (var x = c; x <= hi; x++) {
        members[x] = true;
        if (icase && _isAlpha(x)) members[x ^ 0x20] = true;
      }
    }
    // A negated set under -i may be matched through the input's case, which
    // past ASCII is musl's tables.
    if (icase && negate) _tables.add(_Table.caseMap);
    final included = <int>[
      for (var x = 1; x < 128; x++)
        if (members[x] != negate) x,
    ];
    if (included.isEmpty && !negate) throw const _Refused();
    if (negate) {
      final excluded = <int>[
        for (var x = 1; x < 128; x++)
          if (members[x]) x,
      ];
      return excluded.isEmpty ? r"[^\u{0}]" : "[^${_ranges(excluded)}]";
    }
    return "[${_ranges(included)}]";
  }

  static String _ranges(List<int> xs) {
    final out = StringBuffer();
    var i = 0;
    while (i < xs.length) {
      var j = i;
      while (j + 1 < xs.length && xs[j + 1] == xs[j] + 1) {
        j++;
      }
      out.write("\\u{${xs[i].toRadixString(16)}}");
      if (j > i) out.write("-\\u{${xs[j].toRadixString(16)}}");
      i = j + 1;
    }
    return out.toString();
  }

  int _indexOf(String s, int from) {
    final r = s.runes.toList();
    for (var i = from; i + r.length <= _p.length; i++) {
      var ok = true;
      for (var j = 0; j < r.length; j++) {
        if (_p[i + j] != r[j]) ok = false;
      }
      if (ok) return i;
    }
    return -1;
  }

  static int _upper(int c) => c >= 0x61 && c <= 0x7a ? c - 32 : c;

  /// musl's ctype over ASCII, and the table it reads past it; digits are
  /// ASCII's alone.
  static (bool Function(int), _Table?) _posixClass(String name) =>
      switch (name) {
        "alpha" => (_isAlpha, _Table.word),
        "digit" => (_isDigit, null),
        "alnum" => ((c) => _isAlpha(c) || _isDigit(c), _Table.word),
        "upper" => ((c) => c >= 0x41 && c <= 0x5a, _Table.word),
        "lower" => ((c) => c >= 0x61 && c <= 0x7a, _Table.word),
        "space" => ((c) => c == 0x20 || (c >= 0x09 && c <= 0x0d), _Table.space),
        "blank" => ((c) => c == 0x20 || c == 0x09, _Table.space),
        "punct" => (
          (c) => c > 0x20 && c < 0x7f && !_isAlpha(c) && !_isDigit(c),
          _Table.other,
        ),
        "print" => ((c) => c >= 0x20 && c < 0x7f, _Table.other),
        "graph" => ((c) => c > 0x20 && c < 0x7f, _Table.other),
        "cntrl" => ((c) => c < 0x20 || c == 0x7f, _Table.other),
        "xdigit" => (
          (c) =>
              _isDigit(c) ||
              (c >= 0x41 && c <= 0x46) ||
              (c >= 0x61 && c <= 0x66),
          null,
        ),
        _ => throw const _Refused(),
      };
}

class _Refused implements Exception {
  const _Refused();
}

/// A musl table a pattern reads, and the characters past ASCII it surely
/// leaves out: a translation's classes are ASCII's, so on a line of only
/// those it answers as musl does.
enum _Table {
  /// Letters and digits, for alpha, alnum, upper, lower and words.
  word,
  space,

  /// punct, print, graph and cntrl, which take in most of what is past
  /// ASCII.
  other,

  /// towlower and towupper, which take four characters past ASCII into it.
  caseMap;

  bool surelyOutside(int c) => switch (this) {
    word => _symbols.any((r) => c >= r.$1 && c <= r.$2),
    space => !_spaces.contains(c),
    other => false,
    caseMap => !const {0x130, 0x131, 0x17f, 0x212a}.contains(c),
  };

  /// Punctuation and symbols with no letter or digit among them: dashes,
  /// quotes, arrows, box drawing, emoji.
  static const _symbols = [
    (0xa0, 0xa9),
    (0xab, 0xb1),
    (0xb4, 0xb4),
    (0xb6, 0xb8),
    (0xbb, 0xbb),
    (0xbf, 0xbf),
    (0xd7, 0xd7),
    (0xf7, 0xf7),
    (0x2000, 0x200a),
    (0x2010, 0x205f),
    (0x2190, 0x23ff),
    (0x2500, 0x27bf),
    (0x1f300, 0x1f64f),
    (0x1f680, 0x1f6ff),
    (0x1f900, 0x1f9ff),
  ];

  /// Every character past ASCII any Unicode version calls a space, and more.
  static const _spaces = {
    0x85, 0xa0, 0x1680, 0x180e, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, //
    0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x200b, 0x2028, 0x2029,
    0x202f, 0x205f, 0x3000, 0xfeff,
  };
}
