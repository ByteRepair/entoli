/// What a reply reads once rendered. Nothing here reaches the screen, so the
/// rules about what a message reads as are tested rather than pasted.
library;

import "dart:convert";

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
/// A message's markdown as HTML: the rich half of what the copy button puts on
/// the clipboard, beside [formattedTextOf], for a word processor to paste with
/// its formatting. Parsed as [formattedTextOf] parses it, so the two halves
/// agree about what a block is.
///
/// Not `markdownToHtml`: that passes HTML the model wrote straight through,
/// where the renderer shows it as the characters it is. Every text node is
/// escaped here, so `<div>` in prose pastes as `<div>`. Styles are inline,
/// since a word processor reads no stylesheet.
String formattedHtmlOf(String markdown) {
  final buffer = StringBuffer();
  final visitor = _HtmlVisitor(buffer);
  for (final node in _parse(markdown)) {
    node.accept(visitor);
  }
  return buffer.toString();
}

/// [fragment] as the document a clipboard's HTML entry holds. The charset is
/// stated because a paste target guesses otherwise, and the fragment markers
/// are what Windows' `HTML Format` header counts its offsets to.
String htmlClipboardDocument(String fragment) =>
    '<html><head><meta charset="utf-8"></head><body>'
    "<!--StartFragment-->$fragment<!--EndFragment--></body></html>";

String escapeHtml(String text) => const HtmlEscape(HtmlEscapeMode.element).convert(text);

String escapeHtmlAttribute(String text) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(text);

/// The inline style each tag pastes with, where its default would not read as
/// the reply did. Shared with the selection's copy, so a block reads the same
/// copied whole or in part.
const htmlTagStyles = {
  "pre": "font-family: Consolas, Menlo, 'Courier New', monospace; "
      "background: #f6f8fa; padding: 8px; white-space: pre-wrap",
  "code": "font-family: Consolas, Menlo, 'Courier New', monospace; background: #f6f8fa",
  "table": "border-collapse: collapse",
  "th": "border: 1px solid #d0d7de; padding: 4px 8px",
  "td": "border: 1px solid #d0d7de; padding: 4px 8px",
  "blockquote": "border-left: 3px solid #d0d7de; margin-left: 0; padding-left: 12px",
};

List<md.Node> _parse(String markdown) => md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parseLines(markdown.split("\n"));

class _HtmlVisitor implements md.NodeVisitor {
  _HtmlVisitor(this.buffer);

  final StringBuffer buffer;

  @override
  bool visitElementBefore(md.Element element) {
    buffer.write("<${element.tag}");
    final style = [
      ?htmlTagStyles[element.tag],
      ?element.attributes["style"],
    ].join("; ");
    for (final MapEntry(:key, :value) in element.attributes.entries) {
      if (key == "style") continue;
      buffer.write(' $key="${escapeHtmlAttribute(value)}"');
    }
    if (style.isNotEmpty) buffer.write(' style="${escapeHtmlAttribute(style)}"');
    buffer.write(">");
    // A void element — `br`, `hr`, `img` — has no children and no end tag.
    return element.children != null;
  }

  @override
  void visitText(md.Text text) => buffer.write(escapeHtml(text.text));

  @override
  void visitElementAfter(md.Element element) => buffer.write("</${element.tag}>");
}

/// What kind of block a rendered paragraph is, read back from the markdown
/// that produced it: the selection's copy has only the paragraph on screen,
/// and whether it was a list item or a cell is not in its text.
enum BlockKind { paragraph, heading, listItem, code, cell, headerCell }

class RenderedBlock {
  const RenderedBlock(
    this.kind, {
    this.level = 0,
    this.ordered = false,
    this.number = 1,
    this.quoted = false,
  });

  final BlockKind kind;

  /// A heading's level.
  final int level;

  /// A list item's list is numbered, and this item is [number] in it.
  final bool ordered;
  final int number;

  /// Inside a block quote.
  final bool quoted;
}

/// A message's blocks by the text each renders as, and its links by theirs.
/// Keyed by text because that is all a rendered paragraph shares with the
/// markdown; whitespace is collapsed on both sides, since the renderer folds a
/// soft line break into a space. Two blocks with the same words answer as the
/// first.
class RenderedOutline {
  RenderedOutline.of(String markdown) {
    for (final node in _parse(markdown)) {
      _walk(node, quoted: false);
    }
  }

  final _blocks = <String, RenderedBlock>{};
  final _links = <String, String>{};

  RenderedBlock? blockOf(String text) => _blocks[_key(text)];

  /// The target of the link whose words include [text]: a link with bold
  /// inside it renders as more than one span.
  String? hrefOf(String text) {
    final key = _key(text);
    if (key.isEmpty) return null;
    return _links[key] ??
        _links.entries.where((link) => link.key.contains(key)).firstOrNull?.value;
  }

  static String _key(String text) => text.replaceAll(RegExp(r"\s+"), " ").trim();

  void _add(md.Node node, RenderedBlock block) =>
      _blocks.putIfAbsent(_key(node.textContent), () => block);

  void _walk(md.Node node, {required bool quoted, RenderedBlock? item}) {
    if (node is! md.Element) return;
    switch (node.tag) {
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6":
        _add(node, RenderedBlock(BlockKind.heading,
            level: int.parse(node.tag.substring(1)), quoted: quoted));
      case "p":
        _add(node, item ?? RenderedBlock(BlockKind.paragraph, quoted: quoted));
      case "pre":
        _add(node, RenderedBlock(BlockKind.code, quoted: quoted));
        return;
      case "th":
        _add(node, RenderedBlock(BlockKind.headerCell, quoted: quoted));
      case "td":
        _add(node, RenderedBlock(BlockKind.cell, quoted: quoted));
      case "a":
        if (node.attributes["href"] case final href?) {
          _links.putIfAbsent(_key(node.textContent), () => href);
        }
      case "blockquote":
        for (final child in node.children ?? const <md.Node>[]) {
          _walk(child, quoted: true);
        }
        return;
      case "ul" || "ol":
        final ordered = node.tag == "ol";
        var number = int.tryParse(node.attributes["start"] ?? "") ?? 1;
        for (final li in node.children ?? const <md.Node>[]) {
          if (li is! md.Element) continue;
          final block = RenderedBlock(BlockKind.listItem,
              ordered: ordered, number: number++, quoted: quoted);
          // A tight item's words are its own children; a loose one's are its
          // paragraphs, which the `p` case files with this item's kind.
          final inline = [
            for (final child in li.children ?? const <md.Node>[])
              if (child is md.Text ||
                  (child is md.Element && !_blockTags.contains(child.tag)))
                child,
          ];
          if (inline.isNotEmpty) {
            _blocks.putIfAbsent(
                _key(inline.map((child) => child.textContent).join()), () => block);
          }
          for (final child in li.children ?? const <md.Node>[]) {
            _walk(child, quoted: quoted, item: block);
          }
        }
        return;
    }
    for (final child in node.children ?? const <md.Node>[]) {
      _walk(child, quoted: quoted, item: node.tag == "p" ? null : item);
    }
  }

  static const _blockTags = {
    "p", "ul", "ol", "pre", "blockquote", "table", "hr",
    "h1", "h2", "h3", "h4", "h5", "h6",
  };
}
