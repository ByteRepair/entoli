import "dart:io";

import "package:flutter_test/flutter_test.dart";

/// A directory of its own for one test, deleted after it.
Directory tempDir([String prefix = "entoli_shell_test_"]) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}
