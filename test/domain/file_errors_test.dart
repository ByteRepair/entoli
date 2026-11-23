import "package:entoli_core/model/documents.dart";
import "package:entoli_core/model/file_errors.dart";
import "package:file/file.dart";
import "package:file/local.dart";
import "package:file/memory.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "../harness.dart";

void main() {
  // The disk raises dart:io's subclass and memory the plain exception, and
  // the core reads both as one.
  for (final (name, make) in [
    ("the disk", () => (const LocalFileSystem(), tempDir().path)),
    ("memory", () => (MemoryFileSystem(), "/data")),
  ]) {
    group(name, () {
      late FileSystem fs;
      late String dir;
      setUp(() => (fs, dir) = make());

      test("a missing file is not found", () {
        expect(
          () => fs.file(p.join(dir, "gone")).readAsStringSync(),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.isNotFound,
              "isNotFound",
              isTrue,
            ),
          ),
        );
      });

      test("a document never written reads as nothing", () {
        expect(Documents(fs).read(p.join(dir, "settings.json")), isNull);
      });

      test("a document whose folder is not there reads as nothing", () {
        expect(Documents(fs).read(p.join(dir, "gone", "project.json")), isNull);
      });
    });
  }
}
