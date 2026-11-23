/// The workspace's packages as the structure tests see them.
library;

import "dart:io";

import "package:path/path.dart" as p;

/// The two front ends, each binding the core and the adapters it chose.
const frontEnds = ["agent_chat", "entoli_share_viewer"];

/// The core's `lib/`.
final coreLib = p.normalize(p.absolute("packages", "entoli_core", "lib"));

/// The adapters' `lib/`s by package name: every `packages/entoli_*` but the
/// core and the share viewer, each a platform capability a front end binds.
final adapters = {
  for (final dir in Directory("packages").listSync().whereType<Directory>())
    if (p.basename(dir.path) case final name
        when name.startsWith("entoli_") &&
            name != "entoli_core" &&
            !frontEnds.contains(name))
      name: p.normalize(p.absolute(dir.path, "lib")),
};

/// The Dart sources under [dir], generated ones aside.
Iterable<File> dartSources(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where(
      (f) =>
          f.path.endsWith(".dart") &&
          !f.path.endsWith(".g.dart") &&
          !f.path.endsWith(".freezed.dart"),
    );
