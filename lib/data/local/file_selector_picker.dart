import "package:file_selector/file_selector.dart";

import "../../domain/attachment_picker.dart";
import "../../domain/models.dart";
import "../mime.dart";

/// The platform's own file chooser, through `file_selector` — one plugin
/// covering every platform the app runs on.
class FileSelectorPicker implements AttachmentPicker {
  const FileSelectorPicker();

  static const _images = XTypeGroup(
    label: "Images",
    extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif"],
    mimeTypes: ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"],
    uniformTypeIdentifiers: ["public.image"],
  );

  @override
  Future<List<Attachment>> pick(AttachmentKind kind) async {
    final files = await openFiles(
      acceptedTypeGroups: switch (kind) {
        AttachmentKind.image => const [_images],
        AttachmentKind.file => const <XTypeGroup>[],
      },
    );
    return Future.wait(files.map(_read));
  }

  Future<Attachment> _read(XFile file) async {
    final bytes = await file.readAsBytes();
    return Attachment(
        filename: file.name,
        mimeType: attachmentMime(file.name, bytes, declared: file.mimeType),
        bytes: bytes);
  }
}
