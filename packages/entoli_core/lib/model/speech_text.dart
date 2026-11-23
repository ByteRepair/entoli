/// Turning a reply into something worth hearing. Nothing here reaches a
/// speaker, so the rules about what gets said are tested rather than heard.
library;

final _fence = RegExp(r"^\s*(```|~~~)");
final _rule = RegExp(r"^\s*([-*_])\s*\1\s*\1[\s\-*_]*$");
final _bullet = RegExp(r"^\s*([-*+]|\d+[.)])\s+");
final _quote = RegExp(r"^\s*>+\s?");
final _heading = RegExp(r"^\s*#{1,6}\s+");
final _image = RegExp(r"!\[[^\]]*\]\([^)]*\)");
final _link = RegExp(r"\[([^\]]*)\]\([^)]*\)");
final _emphasis = RegExp(r"(\*{1,3}|_{1,3}|~~)(?=\S)(.*?)(?<=\S)\1");
final _tag = RegExp(r"<[^>\s][^>]*>");
final _blanks = RegExp(r"\n{3,}");
final _tableRule = RegExp(r"^[\s|:-]+$");

/// How a line has to start for any of the anchored rules to reach it, or for
/// it to be able to become a rule or a table's own row once it ends.
final _marked = RegExp(r"^\s*([-*_+>#:|]|\d+[.)])");

/// A reply as it should be read aloud: markdown is written to be looked at, and
/// most of its punctuation is layout. **Fenced code is dropped whole** rather
/// than flattened — a command read out character by character is unusable to
/// listen to and unusable to type from, and the conversation is still on
/// screen.
String speakable(String markdown) {
  final out = <String>[];
  var inFence = false;
  for (final line in markdown.split("\n")) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      continue;
    }
    final said = _spoken(line, inFence);
    if (said != null) out.add(said);
  }
  return _joined(out);
}

/// One line as it should be read, or null where it is layout rather than
/// words. Whether it is inside a fence is the caller's: it is the only thing
/// that carries from one line to the next, and so the only thing
/// [SpeakableText] has to keep.
String? _spoken(String line, bool inFence) {
  if (inFence || _rule.hasMatch(line)) return null;
  var text = line
      .replaceAll(_quote, "")
      .replaceAll(_heading, "")
      .replaceAll(_bullet, "")
      .replaceAll(_image, "")
      .replaceAllMapped(_link, (m) => m[1] ?? "")
      .replaceAllMapped(_emphasis, (m) => m[2] ?? "")
      .replaceAll(_tag, "")
      .replaceAll("`", "");
  // A table row read aloud is a run of pipes; the cells are still words.
  if (text.trimLeft().startsWith("|")) {
    if (_tableRule.hasMatch(text)) return null;
    text = text
        .split("|")
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .join(", ");
  }
  return text.trimRight();
}

String _joined(List<String> lines) =>
    lines.join("\n").replaceAll(_blanks, "\n\n").trim();

/// [speakable] over a reply that is still being written. Fed the whole text
/// each time, like [SentenceSplitter] and for the same reason — that is what
/// the caller has — and a shorter one than last time is a different reply.
///
/// What it saves is that a reply only ever grows: every line before the last
/// break is settled, so it is stripped once instead of once per flush of the
/// turn. Stripping is eight passes over each line, and the transcript is
/// redrawn about sixty times a second, so on the whole reply each time the
/// cost over a turn is quadratic.
///
/// That leaves the line being written, which is stripped afresh every look and
/// so is quadratic in its own length — a reply written as one long paragraph
/// settles nothing until it ends. So a line the rules cannot reach is trimmed
/// rather than stripped: see [_plain]. Settling inside a line would be the
/// other answer and is not worth its price — a split point has to be outside
/// every construct, and a sentence end is not one. `. ` falls inside
/// `[Fig. 3](x)` and `*One. Two*` as readily as a space does.
class SpeakableText {
  /// The settled lines, already joined: a string rather than the list of them,
  /// so that a look costs one copy of it rather than a join of every line.
  var _prefix = "";

  var _text = "";
  var _was = "";

  /// How much of [_text] the settled lines cover, and whether that point is
  /// inside a fence.
  var _done = 0;
  var _inFence = false;

  /// How much of the line being written has been looked at for markup, and
  /// whether any was found. Markup only ever arrives, so a line that has some
  /// has it for good — and a line that has none is one every unanchored rule
  /// leaves alone.
  var _scanned = 0;
  var _dirty = false;

  String of(String markdown) {
    // The same reply again, which is most looks: a turn changes more than its
    // text and the transcript is redrawn for all of it. Identity first, since
    // `startsWith` below walks the whole reply to answer the same question.
    if (identical(markdown, _text)) return _was;
    // Length first, for the reason [SentenceSplitter.add] checks it first.
    if (markdown.length < _text.length || !markdown.startsWith(_text)) {
      _prefix = "";
      _done = 0;
      _inFence = false;
      _scanned = 0;
      _dirty = false;
    } else if (markdown.length == _text.length) {
      return _was;
    }
    _text = markdown;

    final settled = markdown.lastIndexOf("\n") + 1;
    if (settled > _done) {
      for (final line in markdown.substring(_done, settled - 1).split("\n")) {
        if (_fence.hasMatch(line)) {
          _inFence = !_inFence;
          continue;
        }
        final said = _spoken(line, _inFence);
        if (said != null) _settle(said);
      }
      _done = settled;
      _scanned = settled;
      _dirty = false;
    }

    // The line still being written: stripped afresh every time, and its fence
    // not counted — an opening fence is not open until the line it is on ends.
    final tail = markdown.substring(_done);
    final String? said;
    if (_plain(tail)) {
      said = tail.trimRight();
    } else {
      said = _fence.hasMatch(tail) ? null : _spoken(tail, _inFence);
    }
    final out = said == null || said.isEmpty ? _prefix : _with(said);
    return _was = out.trim();
  }

  /// Whether [_spoken] would do no more to the line being written than trim it,
  /// which is what a paragraph of prose is. The anchored rules read only how
  /// the line starts and the rest read only the characters in [_markup], so a
  /// line with neither is one all eight passes are about to leave alone.
  bool _plain(String tail) {
    for (; _scanned < _text.length; _scanned++) {
      if (_markup.contains(_text.codeUnitAt(_scanned))) {
        _dirty = true;
        _scanned = _text.length;
        break;
      }
    }
    return !_dirty && !_inFence && !_marked.hasMatch(tail);
  }

  void _settle(String line) {
    // Two blank lines in a row is the `\n{3,}` collapse, done as they arrive.
    // A settled line never ends in whitespace — [_spoken] trims its right — so
    // a prefix ending in a break is one whose last line was blank.
    if (line.isEmpty && (_prefix.isEmpty || _prefix.endsWith("\n"))) return;
    _prefix = _with(line);
  }

  String _with(String line) => _prefix.isEmpty ? line : "$_prefix\n$line";

  /// What the rules that are not anchored to the start of a line act on:
  /// ``* _ ~ ` [ <`` and `|`. Code units rather than characters, for the reason
  /// [SentenceSplitter._endOfSentence] reads them — this runs over each
  /// character of a reply once.
  static const _markup = {0x2A, 0x5F, 0x7E, 0x60, 0x5B, 0x3C, 0x7C};
}

/// Sentence-sized pieces out of a reply that is still being written, so the
/// first one is spoken while the rest arrives. Fed the whole text each time
/// rather than the delta: that is what the controller has, and a splitter that
/// took deltas would have to be told when the message was replaced.
class SentenceSplitter {
  var _spoken = 0;
  var _text = "";

  /// Anything that has become a whole sentence since the last call. [text] is
  /// the reply so far; a shorter one than last time is a different reply, and
  /// starts this over.
  List<String> add(String text) {
    // Length first: `startsWith` walks the whole reply, and this is asked on
    // every look at a reply that only ever grows.
    if (text.length < _text.length || !text.startsWith(_text)) _spoken = 0;
    _text = text;
    final out = <String>[];
    for (var end = _endOfSentence(); end != null; end = _endOfSentence()) {
      final piece = _text.substring(_spoken, end).trim();
      _spoken = end;
      if (piece.isNotEmpty) out.add(piece);
    }
    return out;
  }

  /// Forget the reply so far. A new one to read, or one abandoned halfway.
  void reset() {
    _spoken = 0;
    _text = "";
  }

  /// The tail, once nothing more is coming. Empty if it was all spoken.
  String flush() {
    final rest = _text.substring(_spoken).trim();
    _spoken = _text.length;
    return rest;
  }

  /// Where the next sentence ends, or null while none has. A terminator counts
  /// only before whitespace, so `3.14` and `file.dart` are not two sentences,
  /// and a line break ends one however it was punctuated — a heading and a
  /// bullet are sentences with no full stop.
  /// Code units rather than characters: `_text[i]` allocates a one-character
  /// string per character scanned, and this runs over the tail of a growing
  /// reply every time one is looked at.
  int? _endOfSentence() {
    var lastBreak = -1;
    var said = false;
    for (var i = _spoken; i < _text.length; i++) {
      final c = _text.codeUnitAt(i);
      if (c == _newline) {
        if (said) return i + 1;
        continue;
      }
      if (_terminators.contains(c)) {
        final next = i + 1 < _text.length ? _text.codeUnitAt(i + 1) : _space;
        if (_isSpace(next) && !_abbreviates(i)) return i + 1;
      }
      final space = _isSpace(c);
      if (!space) said = true;
      // Somewhere to break a sentence that has run on past what is worth
      // waiting for — a paragraph with no full stop in it should not hold up
      // the first sound the user hears.
      if (c == _comma || space) lastBreak = i + 1;
    }
    if (_text.length - _spoken >= _most && lastBreak > _spoken) {
      return lastBreak;
    }
    return null;
  }

  /// Whether the stop at [at] ends an abbreviation rather than a sentence.
  /// Read back to the last space: a word of two letters or fewer before the
  /// stop is an initial, and one with a stop already inside it is `e.g.`.
  bool _abbreviates(int at) {
    if (_text.codeUnitAt(at) != _stop) return false;
    var start = at;
    var inner = false;
    while (start > 0 && !_isSpace(_text.codeUnitAt(start - 1))) {
      start--;
      if (_text.codeUnitAt(start) == _stop) inner = true;
    }
    return at - start <= 2 || inner;
  }

  static const _stop = 0x2E;
  static const _comma = 0x2C;
  static const _space = 0x20;
  static const _newline = 0x0A;

  /// `. ! ? … 。 ！ ？`
  static const _terminators = {
    _stop,
    0x21,
    0x3F,
    0x2026,
    0x3002,
    0xFF01,
    0xFF1F,
  };

  /// Past this, break at the last comma or space rather than wait.
  static const _most = 300;

  static bool _isSpace(int c) =>
      c == _space || c == _newline || c == 0x09 || c == 0x0D;
}
