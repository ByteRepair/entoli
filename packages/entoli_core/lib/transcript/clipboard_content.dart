/// One copy: [plain] for a target that reads text, and [html] — a whole
/// document, as `htmlClipboardDocument` makes one — for one that keeps
/// formatting. A paste takes whichever it reads.
class ClipboardContent {
  const ClipboardContent({required this.plain, this.html});

  final String plain;
  final String? html;
}
