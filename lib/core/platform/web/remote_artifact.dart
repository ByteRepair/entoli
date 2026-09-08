/// Web stub. A browser mirror opens artifacts through the blob-URL path, not
/// through a temp directory; the remote branch is refused in
/// `link_opener.dart` before reaching here. The conditional import keeps
/// `dart:io` off the web build.
Future<String> unzipRemoteArtifact(Object bytes) async {
  throw UnsupportedError("unzipRemoteArtifact is not available on web");
}