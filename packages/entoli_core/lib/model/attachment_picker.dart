import "file_picker.dart";
import "mime.dart";
import "models.dart";

/// What the composer's Image offers.
const imageFileTypes = FileTypes(
  label: "Images",
  extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif"],
  mimeTypes: [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
  ],
  uniformTypeIdentifiers: ["public.image"],
);

/// The files the user chose through [picker] as attachments, or none if they
/// cancelled.
Future<List<Attachment>> pickAttachments(
  FilePicker picker,
  AttachmentKind kind,
) async {
  final files = await picker.files(
    types: switch (kind) {
      AttachmentKind.image => imageFileTypes,
      AttachmentKind.file => null,
    },
  );
  return Future.wait(
    files.map((file) async {
      final bytes = await file.readAsBytes();
      return Attachment(
        filename: file.name,
        mimeType: attachmentMime(file.name, bytes, declared: file.mimeType),
        bytes: bytes,
      );
    }),
  );
}
