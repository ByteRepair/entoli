/// Web stub. A browser mirror opens artifacts through the blob-URL path, not
/// through a temp directory; the remote branch is refused in
/// `link_opener.dart` before reaching here. The conditional import keeps
/// `dart:io` off the web build; the signatures match the io side, so both
/// builds enforce the same call.
library;

import "../../../data/sync/artifact_bytes.dart" show ArtifactBytes;

class RemoteArtifacts {
  RemoteArtifacts(ArtifactBytes hub);

  Future<String?> fetch(String chatId, String artifactId,
          {required String entryFile}) async =>
      throw UnsupportedError("RemoteArtifacts is not available on web");
}