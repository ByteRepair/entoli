import "dart:typed_data";

/// Web stub. A browser mirror opens artifacts through the blob-URL path, not
/// through a temp directory; the remote branch is refused in
/// `link_opener.dart` before reaching here. The conditional import keeps
/// `dart:io` off the web build; the signature matches the io side, so both
/// builds enforce the same call.
Future<String> unzipRemoteArtifact(Uint8List bytes) async {
  throw UnsupportedError("unzipRemoteArtifact is not available on web");
}
