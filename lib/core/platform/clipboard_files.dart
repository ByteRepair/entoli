/// Files on the clipboard, for the composer's paste: the runner's channel.
library;

import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../data/mime.dart";
import "../../domain/clipboard_files.dart";
import "../../domain/models.dart";
import "../log.dart";

const _channel = MethodChannel("agent_chat/clipboard");

ClipboardFiles createClipboardFiles() => const ChannelClipboardFiles();

/// The runner's `readFiles`, which answers with a path for a file copied in a
/// file manager and the bytes for an image copied on its own. Each runner
/// decides "is this text" by its own clipboard's types, so it answers nothing
/// for text and the field pastes it.
class ChannelClipboardFiles implements ClipboardFiles {
  const ChannelClipboardFiles();

  @override
  Future<List<Attachment>> read() async {
    final List<Object?> entries;
    try {
      entries = await _channel.invokeListMethod<Object?>("readFiles") ?? const [];
    } on MissingPluginException catch (_) {
      return const [];
    } on PlatformException catch (e) {
      logFailure("clipboard", "reading pasted files failed", e);
      return const [];
    }
    final read = await Future.wait([
      for (final entry in entries.whereType<Map<Object?, Object?>>())
        if (entry["path"] case final String path)
          _readPath(path)
        else if (entry["bytes"] case final Uint8List bytes)
          Future.value(pastedAttachment(bytes,
              name: entry["name"] as String?, declared: entry["mime"] as String?)),
    ]);
    return read.nonNulls.toList();
  }
}

Future<Attachment?> _readPath(String path) async {
  // A copied folder is in the list too, and has no bytes to attach.
  if (!await FileSystemEntity.isFile(path)) return null;
  try {
    return pastedAttachment(await File(path).readAsBytes(), name: p.basename(path));
  } on FileSystemException catch (e) {
    logFailure("clipboard", "pasted file unreadable", e.osError ?? e.message);
    return null;
  }
}
