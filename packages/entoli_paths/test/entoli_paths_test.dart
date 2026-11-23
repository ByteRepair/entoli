@TestOn("linux")
library;

import "dart:io";

import "package:entoli_paths/entoli_paths.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  // A test is a debug build, so the leaf is the debug one.
  test(
    "Linux keeps the data under ~/.config and the cache under XDG's",
    () async {
      final dirs = appDirectories(home: "/home/u");
      expect(await dirs.data, "/home/u/.config/entoli-debug");
      final xdg = Platform.environment["XDG_CACHE_HOME"];
      expect(await dirs.cache, "${xdg ?? "/home/u/.cache"}/entoli-debug");
    },
  );
}
