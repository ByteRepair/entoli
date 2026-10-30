import "dart:typed_data";

import "package:mime/mime.dart";

import "../domain/models.dart";

/// What a viewer is told a workspace file is — an `ACTION_VIEW` intent's type,
/// a `Blob`'s. `application/octet-stream` throws away the one fact that decides
/// whether anything opens it at all, so an unrecognised file is offered as text,
/// which is what most of a workspace is.
///
/// [attachmentMime] is a stricter answer to a similar question: an attachment
/// arrives with bytes, so it can sniff for a NUL before
/// claiming a file reads as text. Here there is only the name.
String viewerMime(String path) {
  final looked = lookupMimeType(path);
  if (looked != null && looked != "application/octet-stream") return looked;
  return "text/plain";
}

/// What an attachment is: what came with it, then its bytes and [name].
/// Nothing names a type for most source files, and `application/octet-stream`
/// throws away the one fact that matters — whether the bytes read as text. No
/// NUL in the first few KB is the usual test for that.
String attachmentMime(String name, Uint8List bytes, {String? declared}) {
  final type = declared ?? sniffMime(bytes, name: name);
  if (type != null && type != "application/octet-stream") return type;
  return bytes.take(4096).contains(0)
      ? "application/octet-stream"
      : "text/plain";
}

/// A pasted file as an attachment. A paste without a name, an image copied on
/// its own, is named for what its bytes are.
Attachment pastedAttachment(Uint8List bytes, {String? name, String? declared}) {
  final type = attachmentMime(name ?? "", bytes, declared: declared);
  return Attachment(
    filename: name ?? "pasted.${extensionFromMime(type) ?? "bin"}",
    mimeType: type,
    bytes: bytes,
  );
}

/// What [bytes] are by their magic number, then by [name]'s extension where
/// one is given. Null where neither says.
String? sniffMime(Uint8List bytes, {String name = ""}) => lookupMimeType(
  name,
  headerBytes: bytes.length > defaultMagicNumbersMaxLength
      ? Uint8List.sublistView(bytes, 0, defaultMagicNumbersMaxLength)
      : bytes,
);
