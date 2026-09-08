import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:agent_chat/core/platform/io/remote_artifact.dart";
import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  Uint8List zipOf(Map<String, List<int>> files) {
    final archive = Archive();
    for (final MapEntry(key: name, value: bytes) in files.entries) {
      archive.add(ArchiveFile.bytes(name, Uint8List.fromList(bytes)));
    }
    return ZipEncoder().encodeBytes(archive, autoClose: true);
  }

  test("entries land under the temp root, subdirectories included", () async {
    final dir = await unzipRemoteArtifact(zipOf({
      "index.html": utf8.encode("<p>hi</p>"),
      "assets/style.css": utf8.encode("body{}"),
    }));
    addTearDown(() => Directory(dir).delete(recursive: true));

    expect(File("$dir/index.html").readAsStringSync(), "<p>hi</p>");
    expect(File("$dir/assets/style.css").readAsStringSync(), "body{}");
  });

  test("a member naming somewhere else is flattened inside", () async {
    final dir = await unzipRemoteArtifact(zipOf({
      "../escape.html": utf8.encode("no"),
    }));
    addTearDown(() => Directory(dir).delete(recursive: true));

    // The sanitiser keeps the segment it can: the file is written, but where
    // it can name nothing outside the temp root.
    expect(File("$dir/escape.html").existsSync(), isTrue);
    expect(File("$dir/../escape.html").existsSync(), isFalse);
  });
}
