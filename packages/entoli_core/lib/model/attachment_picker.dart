import "file_picker.dart";
import "mime.dart";
import "models.dart";

/// The files the user chose through [picker] as attachments, or none if they
/// cancelled.
Future<List<Attachment>> pickAttachments(
  FilePicker picker,
  AttachmentKind kind,
) async {
  final files = switch (kind) {
    AttachmentKind.image => await picker.images(),
    AttachmentKind.photo => [?await picker.photo()],
    AttachmentKind.file => await picker.files(),
  };
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
