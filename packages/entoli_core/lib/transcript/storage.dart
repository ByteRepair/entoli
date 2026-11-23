import "package:file/file.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../model/workspace.dart";

/// What the chats and their workspaces are on: the disk, or memory in a
/// browser. Bound where the app is assembled, to the config's.
final fileSystemProvider = Provider<FileSystem>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);

final workspaceProvider = Provider<Workspace>(
  (ref) => Workspace(ref.watch(fileSystemProvider)),
);
