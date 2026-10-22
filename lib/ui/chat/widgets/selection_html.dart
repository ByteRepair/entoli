/// A selection of a rendered reply as HTML, for the clipboard's rich half.
///
/// The selection API answers in plain text only, so this reads the rendered
/// paragraphs themselves: the spans under a selected range say what was bold,
/// italic, code or a link, and the reply's markdown says which kind of block
/// each paragraph was. See "Selecting a reply, and copying it".
library;

import "package:flutter/rendering.dart";

import "../../../domain/formatted_text.dart";
import "../../fonts.dart" show monoFamily;

/// One selected stretch of a rendered paragraph, in the order the selection
/// runs. [paragraph] is null where the selectable was not a paragraph's own —
/// a code block or a table under a scroll registers as a container of its own
/// — and then [text] is all there is.
class SelectedPiece {
  SelectedPiece({
    required this.text,
    required this.paragraph,
    required this.start,
    required this.end,
    required this.sameLine,
    this.monospace = false,
  });

  final String text;
  final RenderParagraph? paragraph;
  final int start;
  final int end;

  /// On the rendered line of the piece before it: a table's next cell.
  final bool sameLine;

  /// Drawn in the code face throughout: a code block, where [paragraph] is
  /// null because the block scrolls.
  final bool monospace;
}

/// The rendered paragraphs under [root], for [paragraphOf] to match against.
List<RenderParagraph> paragraphsUnder(RenderObject? root) {
  final found = <RenderParagraph>[];
  void visit(RenderObject child) {
    if (child is RenderParagraph) found.add(child);
    child.visitChildren(visit);
  }

  if (root != null) visit(root);
  return found;
}

/// The paragraph [selectable] is a fragment of. A fragment reports its
/// paragraph's transform as its own and indexes its paragraph's whole text,
/// which is what is matched: the fragment type is private to the framework.
RenderParagraph? paragraphOf(
  Selectable selectable,
  List<RenderParagraph> paragraphs,
  String selected,
  SelectedContentRange range,
) {
  final transform = selectable.getTransformTo(null);
  final start = range.startOffset < range.endOffset ? range.startOffset : range.endOffset;
  final end = start + selected.length;
  for (final paragraph in paragraphs) {
    if (!paragraph.attached || paragraph.getTransformTo(null) != transform) continue;
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    if (end <= text.length && text.substring(start, end) == selected) return paragraph;
  }
  return null;
}

/// [pieces] as an HTML fragment, blocks grouped back into the lists, tables
/// and quotes [outline] says they came from.
String selectionHtml(List<SelectedPiece> pieces, RenderedOutline outline) {
  final out = StringBuffer();
  String? list;
  var table = false;
  var row = false;
  var quote = false;

  void closeList() {
    if (list != null) out.write("</$list>");
    list = null;
  }

  void closeTable() {
    if (row) out.write("</tr>");
    if (table) out.write("</table>");
    table = row = false;
  }

  for (var i = 0; i < pieces.length; i++) {
    final piece = pieces[i];
    final paragraph = piece.paragraph;
    final fullText = paragraph?.text.toPlainText(includeSemanticsLabels: false);
    var block = (fullText == null ? null : outline.blockOf(fullText)) ??
        RenderedBlock(piece.monospace || isMonospace(paragraph) ? BlockKind.code : BlockKind.paragraph);
    // An item picked up from the middle is its words, not an item: the bullet
    // was not part of what was selected.
    if (block.kind == BlockKind.listItem && piece.start > 0) {
      block = RenderedBlock(BlockKind.paragraph, quoted: block.quoted);
    }

    // A paragraph split by a placeholder is two fragments and one block.
    final buffer = StringBuffer(_inline(piece, block, outline));
    while (paragraph != null &&
        i + 1 < pieces.length &&
        pieces[i + 1].paragraph == paragraph) {
      buffer.write(_inline(pieces[++i], block, outline));
    }
    final inline = buffer.toString();

    if (block.quoted != quote) {
      closeList();
      closeTable();
      out.write(quote ? "</blockquote>" : _open("blockquote"));
      quote = block.quoted;
    }
    switch (block.kind) {
      case BlockKind.cell || BlockKind.headerCell:
        closeList();
        if (!table) out.write(_open("table"));
        if (!table || !piece.sameLine) {
          if (row) out.write("</tr>");
          out.write("<tr>");
        }
        table = row = true;
        final tag = block.kind == BlockKind.headerCell ? "th" : "td";
        out.write("${_open(tag)}$inline</$tag>");
        continue;
      case BlockKind.listItem:
        closeTable();
        final tag = block.ordered ? "ol" : "ul";
        if (list != tag) {
          closeList();
          out.write(block.ordered && block.number != 1
              ? '<ol start="${block.number}">'
              : "<$tag>");
          list = tag;
        }
        out.write("<li>$inline</li>");
        continue;
      case BlockKind.heading:
        out.write("<h${block.level}>$inline</h${block.level}>");
      case BlockKind.code:
        out.write("${_open("pre")}$inline</pre>");
      case BlockKind.paragraph:
        out.write("<p>$inline</p>");
    }
    closeList();
    closeTable();
  }
  closeList();
  closeTable();
  if (quote) out.write("</blockquote>");
  return out.toString();
}

String _open(String tag) => '<$tag style="${escapeHtmlAttribute(htmlTagStyles[tag]!)}">';

/// Every word of [paragraph] is in the code face. The root span is the
/// ambient style, so it is the words that are asked.
bool isMonospace(RenderParagraph? paragraph) {
  if (paragraph == null) return false;
  var words = false;
  var mono = true;
  void visit(InlineSpan span, TextStyle? inherited) {
    final style = inherited?.merge(span.style) ?? span.style;
    if (span is! TextSpan) return;
    if (span.text?.trim().isNotEmpty ?? false) {
      words = true;
      mono &= style?.fontFamily == monoFamily;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, style);
    }
  }

  visit(paragraph.text, null);
  return words && mono;
}

/// The piece's range of its paragraph, each run of text in the tags its style
/// draws it with. Runs that share their tags share them in the HTML too, so a
/// highlighted code block is one block of text rather than a span per token.
String _inline(SelectedPiece piece, RenderedBlock block, RenderedOutline outline) {
  final paragraph = piece.paragraph;
  final code = block.kind == BlockKind.code;
  if (paragraph == null) return _text(piece.text, code: code);

  final runs = <({String tags, String? href, StringBuffer text})>[];
  var offset = 0;
  void visit(InlineSpan span, TextStyle? inherited) {
    final style = inherited?.merge(span.style) ?? span.style;
    if (span is! TextSpan) {
      offset += 1;
      return;
    }
    final text = span.text;
    if (text != null) {
      final from = (piece.start - offset).clamp(0, text.length);
      final to = (piece.end - offset).clamp(0, text.length);
      offset += text.length;
      if (from < to) {
        final href = span.recognizer == null ? null : outline.hrefOf(text);
        final tags = _tags(style, block);
        if (runs.lastOrNull case final last?
            when last.tags == tags && last.href == href) {
          last.text.write(text.substring(from, to));
        } else {
          runs.add((tags: tags, href: href, text: StringBuffer(text.substring(from, to))));
        }
      }
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, style);
    }
  }

  visit(paragraph.text, null);
  final out = StringBuffer();
  for (final run in runs) {
    final tags = run.tags.isEmpty ? const <String>[] : run.tags.split(",");
    if (run.href != null) out.write('<a href="${escapeHtmlAttribute(run.href!)}">');
    for (final tag in tags) {
      out.write(tag == "code" ? _open("code") : "<$tag>");
    }
    out.write(_text(run.text.toString(), code: code));
    for (final tag in tags.reversed) {
      out.write("</$tag>");
    }
    if (run.href != null) out.write("</a>");
  }
  return out.toString();
}

/// The inline tags [style] reads as, comma-joined so runs compare by value.
/// What the whole block is drawn in is not a tag: a heading is bold, and a
/// code block monospace, without either being said again inside it.
String _tags(TextStyle? style, RenderedBlock block) {
  final weight = style?.fontWeight?.value ?? 400;
  return [
    if (style?.fontFamily == monoFamily && block.kind != BlockKind.code) "code",
    if (weight >= 600 &&
        block.kind != BlockKind.heading &&
        block.kind != BlockKind.headerCell)
      "b",
    if (style?.fontStyle == FontStyle.italic) "i",
    if (style?.decoration?.contains(TextDecoration.lineThrough) ?? false) "s",
  ].join(",");
}

/// Line breaks are kept by a `pre` and are `br` anywhere else.
String _text(String text, {required bool code}) {
  final escaped = escapeHtml(text);
  return code ? escaped : escaped.replaceAll("\n", "<br>");
}
