import "package:flutter_riverpod/flutter_riverpod.dart";

import "../model/file_handoff.dart";
import "../model/link_opener.dart";

/// The routes out of the app for a file, bound where the app is assembled.
final fileHandoffProvider = Provider<FileHandoff>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);

/// How a link and an artifact are opened, bound where the app is assembled.
final linkOpenerProvider = Provider<LinkOpener>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);
