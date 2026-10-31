/// The ways a [CopiedDocument] is written out, and the clipboard entry they
/// make together: HTML for a target that keeps formatting — a word processor
/// pastes the headings, lists and bold — and markdown for one that takes plain
/// text — an editor, a terminal, another markdown field — so what lands there
/// is the reply as it was written rather than the words with the rest gone.
library;

import "dart:convert";
import "dart:math" as math;

import "../../core/platform/rich_clipboard.dart";
import "package:flutter/rendering.dart" show RenderObject;

import "../../domain/formatted_text.dart"
    show
        escapeHtml,
        escapeHtmlAttribute,
        formattedHtmlOf,
        formattedTextOf,
        htmlClipboardDocument,
        htmlTagStyles;
import "copied_document.dart";
import "selectable_formula.dart" show formulaPicturesUnder;

/// One way of writing a selection.
abstract interface class CopyFormat {
  String write(CopiedDocument document);
}

/// What a copy puts on the clipboard: both formats of one [document], its
/// formulas drawn for the formatted half.
Future<ClipboardContent> clipboardContentOf(CopiedDocument document) async =>
    ClipboardContent(
      plain: const MarkdownCopyFormat().write(document),
      html: htmlClipboardDocument(
        const HtmlCopyFormat().write(await document.drawn()),
      ),
    );

/// What the copy button puts on the clipboard: the whole of [markdown],
/// formatted, each formula pasting as the picture [drawn] has of it — the
/// one a selection's copy pastes, so a formula copied either way pastes
/// alike.
Future<ClipboardContent> replyContentOf(
  String markdown,
  RenderObject? drawn,
) async {
  final pictures = await formulaPicturesUnder(drawn);
  return ClipboardContent(
    plain: formattedTextOf(markdown),
    html: htmlClipboardDocument(
      formattedHtmlOf(
        markdown,
        formula: (written) => formulaHtml(written, pictures[written]),
      ),
    ),
  );
}

/// A formula as HTML: its [picture], at the size it was on screen, or its
/// TeX where it could not be drawn.
String formulaHtml(String written, FormulaPicture? picture) => picture == null
    ? escapeHtml(written)
    : '<img src="data:image/png;base64,${base64Encode(picture.png)}" '
          'alt="${escapeHtmlAttribute(written)}" '
          'width="${picture.width.round()}" height="${picture.height.round()}" '
          'style="vertical-align: middle">';

/// An HTML fragment, blocks grouped back into the lists, tables and quotes
/// they were drawn in. Styles are inline, since a word processor reads no
/// stylesheet; a formula is its picture, at the size it was on screen — no
/// word processor can typeset TeX, and an unknown element would be dropped
/// with its text — or its TeX where it could not be drawn.
class HtmlCopyFormat implements CopyFormat {
  const HtmlCopyFormat();

  @override
  String write(CopiedDocument document) {
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

    for (final block in document.blocks) {
      final inline = _inlines(block);
      if (block.quoted != quote) {
        closeList();
        closeTable();
        out.write(quote ? "</blockquote>" : _open("blockquote"));
        quote = block.quoted;
      }
      // Closed before this block is written, or it lands inside them.
      if (block.kind != BlockKind.listItem) closeList();
      if (!block.isCell) closeTable();
      switch (block.kind) {
        case BlockKind.cell || BlockKind.headerCell:
          if (!table) out.write(_open("table"));
          if (!table || !block.sameRow) {
            if (row) out.write("</tr>");
            out.write("<tr>");
          }
          table = row = true;
          final tag = block.kind == BlockKind.headerCell ? "th" : "td";
          out.write("${_open(tag)}$inline</$tag>");
        case BlockKind.listItem:
          final tag = block.ordered ? "ol" : "ul";
          if (list != tag) {
            closeList();
            out.write(
              block.ordered && block.number != 1
                  ? '<ol start="${block.number}">'
                  : "<$tag>",
            );
            list = tag;
          }
          out.write("<li>$inline</li>");
        case BlockKind.heading:
          out.write("<h${block.level}>$inline</h${block.level}>");
        case BlockKind.code:
          out.write("${_open("pre")}$inline</pre>");
        case BlockKind.paragraph:
          final display = block.inlines.any(
            (inline) => inline is CopiedFormula && inline.display,
          );
          out.write(
            display
                ? '<p style="text-align: center">$inline</p>'
                : "<p>$inline</p>",
          );
      }
    }
    closeList();
    closeTable();
    if (quote) out.write("</blockquote>");
    return out.toString();
  }

  static String _open(String tag) =>
      '<$tag style="${escapeHtmlAttribute(htmlTagStyles[tag]!)}">';

  static String _inlines(CopiedBlock block) {
    final code = block.kind == BlockKind.code;
    final out = StringBuffer();
    for (final inline in block.inlines) {
      switch (inline) {
        case CopiedFormula(:final written, :final picture):
          out.write(formulaHtml(written, picture));
        case CopiedText(:final text, :final marks, :final href):
          final tags = [
            if (marks.contains(TextMark.code)) "code",
            if (marks.contains(TextMark.bold)) "b",
            if (marks.contains(TextMark.italic)) "i",
            if (marks.contains(TextMark.strike)) "s",
          ];
          if (href != null) {
            out.write('<a href="${escapeHtmlAttribute(href)}">');
          }
          for (final tag in tags) {
            out.write(tag == "code" ? _open("code") : "<$tag>");
          }
          // Line breaks are kept by a `pre` and are `br` anywhere else.
          final escaped = escapeHtml(text);
          out.write(code ? escaped : escaped.replaceAll("\n", "<br>"));
          for (final tag in tags.reversed) {
            out.write("</$tag>");
          }
          if (href != null) out.write("</a>");
      }
    }
    return out.toString();
  }
}

/// Markdown, as near to how the reply was written as what was selected
/// allows: the blocks' own syntax — heading marks, list markers, fences with
/// their language, table pipes, quote marks — and the runs' — emphasis, code
/// spans, links — with every formula the TeX it was written as.
class MarkdownCopyFormat implements CopyFormat {
  const MarkdownCopyFormat();

  @override
  String write(CopiedDocument document) {
    final out = StringBuffer();
    final rows = <({bool header, List<String> cells})>[];
    CopiedBlock? previous;

    void flushTable() {
      if (rows.isEmpty) return;
      final lines = <String>[];
      for (final (i, row) in rows.indexed) {
        lines.add("| ${row.cells.join(" | ")} |");
        if (i == 0 && row.header) {
          lines.add("|${List.filled(row.cells.length, "---").join("|")}|");
        }
      }
      _append(out, lines.join("\n"), quoted: previous!.quoted);
      rows.clear();
    }

    for (final block in document.blocks) {
      if (block.isCell) {
        if (rows.isEmpty) _separate(out, previous, block);
        if (rows.isEmpty || !block.sameRow) {
          rows.add((header: block.kind == BlockKind.headerCell, cells: []));
        }
        rows.last.cells.add(_inlines(block).replaceAll("|", r"\|"));
        previous = block;
        continue;
      }
      flushTable();
      _separate(out, previous, block);
      _append(out, _block(block), quoted: block.quoted);
      previous = block;
    }
    flushTable();
    return out.toString();
  }

  /// Items of one list are a line apart; anything else a blank line, which
  /// inside a quote is a quote mark on its own.
  static void _separate(
    StringBuffer out,
    CopiedBlock? before,
    CopiedBlock next,
  ) {
    if (before == null) return;
    final sameList =
        before.kind == BlockKind.listItem &&
        next.kind == BlockKind.listItem &&
        before.ordered == next.ordered;
    if (sameList) {
      out.write("\n");
    } else {
      out.write(before.quoted && next.quoted ? "\n>\n" : "\n\n");
    }
  }

  static void _append(StringBuffer out, String text, {required bool quoted}) {
    if (!quoted) return out.write(text);
    out.write(
      text.split("\n").map((line) => line.isEmpty ? ">" : "> $line").join("\n"),
    );
  }

  static String _block(CopiedBlock block) => switch (block.kind) {
    BlockKind.heading => "${"#" * block.level} ${_inlines(block)}",
    BlockKind.listItem =>
      "${block.ordered ? "${block.number}." : "-"} ${_inlines(block)}",
    BlockKind.code => _fenced(block.text, block.language),
    _ => _inlines(block),
  };

  /// A fence longer than any run of backticks inside, so the code cannot
  /// close it.
  static String _fenced(String code, String? language) {
    final longest = _longestBackticks(code);
    final fence = "`" * (longest < 3 ? 3 : longest + 1);
    return "$fence${language ?? ""}\n$code\n$fence";
  }

  static String _inlines(CopiedBlock block) =>
      block.inlines.map(_inline).join();

  static String _inline(CopiedInline inline) => switch (inline) {
    CopiedFormula(:final written) => written,
    CopiedText(:final text, :final marks, :final href) => _run(
      text,
      marks,
      href,
    ),
  };

  /// [text] in its marks, the whitespace at either end kept outside them:
  /// `** bold**` is no emphasis.
  static String _run(String text, Set<TextMark> marks, String? href) {
    if (marks.isEmpty && href == null) return text;
    final lead = RegExp(r"^\s*").firstMatch(text)![0]!;
    final trail = RegExp(r"\s*$").firstMatch(text.substring(lead.length))![0]!;
    var inner = text.substring(lead.length, text.length - trail.length);
    if (inner.isEmpty) return text;
    if (marks.contains(TextMark.code)) inner = _codeSpan(inner);
    if (marks.contains(TextMark.strike)) inner = "~~$inner~~";
    if (marks.contains(TextMark.italic)) inner = "*$inner*";
    if (marks.contains(TextMark.bold)) inner = "**$inner**";
    if (href != null) inner = "[$inner]($href)";
    return "$lead$inner$trail";
  }

  static String _codeSpan(String code) {
    final ticks = "`" * (_longestBackticks(code) + 1);
    final pad = code.startsWith("`") || code.endsWith("`") ? " " : "";
    return "$ticks$pad$code$pad$ticks";
  }

  static int _longestBackticks(String text) => RegExp("`+")
      .allMatches(text)
      .fold(0, (most, run) => math.max(most, run.end - run.start));
}
