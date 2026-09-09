/// What a reply reads once rendered. Nothing here reaches the screen, so the
/// rules about what a message reads as are tested rather than pasted.
library;

import "package:markdown/markdown.dart" as md;

/// A message's markdown as it reads once rendered: the formatted text the copy
/// button takes, where the selection's copy answers from what is on screen.
/// Inline styles fall away, links by the words they carry, blocks as lines.
///
/// Parsed with the same document grammar the renderer reads, and with HTML
/// encoding off the way the renderer has it — encoding on would rewrite the
/// quotes and ampersands of what was said as `&quot;` and friends, entities
/// that were never drawn.
String formattedTextOf(String markdown) {
  final buffer = StringBuffer();
  final visitor = _FormattedTextVisitor(buffer);
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // The renderer's own answer (flutter_markdown_plus builds every document
    // with `encodeHtml: false`): the entities are HTML machinery, and the
    // rendered text is the words they encode.
    encodeHtml: false,
  );
  for (final node in document.parseLines(markdown.split("\n"))) {
    node.accept(visitor);
  }
  return buffer.toString().trimRight();
}

class _FormattedTextVisitor implements md.NodeVisitor {
  _FormattedTextVisitor(this.buffer);

  final StringBuffer buffer;

  /// A paragraph or heading writes into a fresh line, so the next one starts
  /// below it rather than glued to its last word.
  bool _needsBreak = false;

  void _break() {
    if (buffer.isEmpty) return;
    if (_needsBreak) buffer.write("\n");
    _needsBreak = false;
  }

  @override
  bool visitElementBefore(md.Element element) {
    switch (element.tag) {
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6" || "p" || "li":
        _break();
    }
    // The children carry the content; nothing is written for the element
    // itself, so there is nothing to stand in for it.
    return true;
  }

  @override
  void visitText(md.Text text) {
    _break();
    buffer.write(text.text);
  }

  @override
  void visitElementAfter(md.Element element) {
    switch (element.tag) {
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6" || "p" || "li":
        _needsBreak = true;
    }
  }
}