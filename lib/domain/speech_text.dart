/// Turning a reply into something worth hearing. Both halves are pure, so the
/// rules about what gets said are tested rather than heard.
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
    if (inFence || _rule.hasMatch(line)) continue;
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
      if (_tableRule.hasMatch(text)) continue;
      text = text.split("|").map((c) => c.trim()).where((c) => c.isNotEmpty).join(", ");
    }
    out.add(text.trimRight());
  }
  return out.join("\n").replaceAll(_blanks, "\n\n").trim();
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
    if (_text.length - _spoken >= _most && lastBreak > _spoken) return lastBreak;
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
  static const _terminators = {_stop, 0x21, 0x3F, 0x2026, 0x3002, 0xFF01, 0xFF1F};

  /// Past this, break at the last comma or space rather than wait.
  static const _most = 300;

  static bool _isSpace(int c) => c == _space || c == _newline || c == 0x09 || c == 0x0D;
}
