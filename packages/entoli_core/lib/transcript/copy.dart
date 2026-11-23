import "dart:convert";
import "dart:typed_data";

import "clipboard_content.dart";
import "../model/formatted_text.dart";

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
