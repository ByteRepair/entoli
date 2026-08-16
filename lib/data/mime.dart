import "package:mime/mime.dart";

/// What a viewer is told a workspace file is — an `ACTION_VIEW` intent's type,
/// a `Blob`'s. `application/octet-stream` throws away the one fact that decides
/// whether anything opens it at all, so an unrecognised file is offered as text,
/// which is what most of a workspace is.
///
/// `FileSelectorPicker` has a stricter answer to a similar question and keeps
/// it: an attachment arrives with bytes, so it can sniff for a NUL before
/// claiming a file reads as text. Here there is only the name.
String viewerMime(String path) {
  final looked = lookupMimeType(path);
  if (looked != null && looked != "application/octet-stream") return looked;
  return "text/plain";
}
