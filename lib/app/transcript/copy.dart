import "dart:convert";
import "dart:typed_data";

import "../../core/platform/rich_clipboard.dart";
import "../../domain/formatted_text.dart";
import "formula.dart";
import "markdown.dart";

/// A formula as it pastes: a picture, at the size it is drawn.
typedef PastedFormula = ({Uint8List png, double width, double height});

/// What Copy puts on the clipboard for a reply's [markdown]: the formatted
/// text, each formula pasting as [pictures] has it by its TeX as written,
/// or as that TeX where there is none.
ClipboardContent replyClipboard(
  String markdown,
  Map<String, PastedFormula> pictures,
) => ClipboardContent(
  plain: formattedTextOf(markdown),
  html: htmlClipboardDocument(
    formattedHtmlOf(
      markdown,
      formula: (written) => formulaHtml(written, pictures[written]),
    ),
  ),
);

/// A formula as HTML: its [picture], or its TeX where it could not be drawn.
String formulaHtml(String written, PastedFormula? picture) => picture == null
    ? escapeHtml(written)
    : '<img src="data:image/png;base64,${base64Encode(picture.png)}" '
          'alt="${escapeHtmlAttribute(written)}" '
          'width="${picture.width.round()}" height="${picture.height.round()}" '
          'style="vertical-align: middle">';

/// Every formula in [markdown] typeset by [renderer] in black, by its TeX
/// as written: the pictures a copy pastes where no screen has drawn them.
/// One that cannot be typeset is left out.
Future<Map<String, PastedFormula>> formulaPicturesOf(
  String markdown,
  FormulaRenderer renderer,
) async {
  final found = <String, (String, bool)>{};
  void inline(List<Inline> inlines) {
    for (final i in inlines) {
      if (i is FormulaInline) found[i.written] = (i.tex, i.display);
    }
  }

  for (final block in MarkdownDocument.parse(markdown).blocks) {
    switch (block) {
      case FormulaBlock(:final tex, :final written):
        found[written] = (tex, true);
      case ParagraphBlock(:final inlines) || HeadingBlock(:final inlines):
        inline(inlines);
      case TableBlock(:final header, :final rows):
        [...header, ...rows.expand((r) => r)].forEach(inline);
      case _:
    }
  }
  final out = <String, PastedFormula>{};
  for (final MapEntry(key: written, value: (tex, display)) in found.entries) {
    try {
      final image = await renderer.render(
        tex,
        FormulaStyle(
          display: display,
          fontSize: display ? 18 : 16,
          argb: 0xFF000000,
        ),
      );
      if (image.error == null) {
        out[written] = (
          png: image.png,
          width: image.width,
          height: image.height,
        );
      }
    } catch (_) {}
  }
  return out;
}
