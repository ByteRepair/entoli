import "dart:typed_data";

import "package:file_selector/file_selector.dart";

import "../../domain/attachment_picker.dart";
import "../../domain/models.dart";
import "../mime.dart";

/// The platform's own file chooser, through `file_selector` — one plugin
/// covering Linux, Android and the web, the three the app runs on.
class FileSelectorPicker implements AttachmentPicker {
  const FileSelectorPicker();

  static const _images = XTypeGroup(
    label: "Images",
    extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif"],
    mimeTypes: ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp"],
    uniformTypeIdentifiers: ["public.image"],
    webWildCards: ["image/*"],
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
    return Attachment(filename: file.name, mimeType: _mimeOf(file, bytes), bytes: bytes);
  }
}

/// Nothing names a type for most source files, and `application/octet-stream`
/// throws away the one fact that matters — whether the bytes read as text. No
/// NUL in the first few KB is the usual test for that.
String _mimeOf(XFile file, Uint8List bytes) {
  final declared = file.mimeType ?? sniffMime(bytes, name: file.name);
  if (declared != null && declared != "application/octet-stream") return declared;
  return bytes.take(4096).contains(0) ? "application/octet-stream" : "text/plain";
}
