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

  /// The lifecycle is what [RemoteArtifacts] adds over the bare unzip: the
  /// directory outlives the call, the one it replaces goes only after the
  /// new one is in place, and a zip short of its entry file stages nothing
  /// and answers null — with the previous one, if there was one, left alone.
  group("RemoteArtifacts", () {
    late _Hub hub;
    late RemoteArtifacts remote;

    setUp(() {
      hub = _Hub();
      remote = RemoteArtifacts(hub);
    });

    test("answers the directory the zip landed in", () async {
      hub.artifacts["c1/a1"] = zipOf({"index.html": utf8.encode("<p>")});
      final dir =
          await remote.fetch("c1", "a1", entryFile: "index.html");
      addTearDown(() => Directory(dir!).delete(recursive: true));

      expect(File("$dir/index.html").existsSync(), isTrue);
    });

    test("answers null and stages nothing where the entry file is missing",
        () async {
      hub.artifacts["c1/a1"] = zipOf({"other.html": utf8.encode("<p>")});
      final dir = await remote.fetch("c1", "a1", entryFile: "index.html");

      expect(dir, isNull);
    });

    test("answers null where the artifact is not there", () async {
      expect(await remote.fetch("c1", "gone", entryFile: "index.html"), isNull);
    });

    test("a re-fetch replaces the directory and takes the old one down",
        () async {
      hub.artifacts["c1/a1"] = zipOf({"index.html": utf8.encode("<p>v1</p>")});
      final first = await remote.fetch("c1", "a1", entryFile: "index.html");

      hub.artifacts["c1/a1"] = zipOf({"index.html": utf8.encode("<p>v2</p>")});
      final second = await remote.fetch("c1", "a1", entryFile: "index.html");
      expect(second, isNot(first));
      expect(File("$second/index.html").readAsStringSync(), "<p>v2</p>");

      // The delete is fire-and-forget; a poll keeps the test off its timing.
      final gone = Directory(first!);
      for (var i = 0; i < 100 && gone.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gone.existsSync(), isFalse);
    });

    test("a failed re-fetch leaves the staged directory standing", () async {
      hub.artifacts["c1/a1"] = zipOf({"index.html": utf8.encode("<p>v1</p>")});
      final first = await remote.fetch("c1", "a1", entryFile: "index.html");

      hub.artifacts["c1/a1"] = zipOf({"other.html": utf8.encode("<p>")});
      final second = await remote.fetch("c1", "a1", entryFile: "index.html");
      expect(second, isNull);

      expect(Directory(first!).existsSync(), isTrue);
      addTearDown(() => Directory(first).delete(recursive: true));
    });
  });
}

/// What [RemoteArtifacts] asks its hub for, as a map a test writes into.
class _Hub implements ArtifactBytes {
  final artifacts = <String, Uint8List>{};

  @override
  Future<Uint8List?> artifactBytes(String chatId, String artifactId) async =>
      artifacts["$chatId/$artifactId"];
}