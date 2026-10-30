import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../../data/mime.dart";
import "../../../domain/clipboard_files.dart";
import "../../../domain/models.dart";
import "../../log.dart";

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
    final out = <Attachment>[];
    for (final entry in entries.whereType<Map<Object?, Object?>>()) {
      final attachment = entry["path"] is String
          ? await _readPath(entry["path"] as String)
          : _fromBytes(entry);
      if (attachment != null) out.add(attachment);
    }
    return out;
  }

  @override
  Stream<List<Attachment>> get pasted => const Stream.empty();
}

Future<Attachment?> _readPath(String path) async {
  // A copied folder is in the list too, and has no bytes to attach.
  if (!await FileSystemEntity.isFile(path)) return null;
  try {
    final bytes = await File(path).readAsBytes();
    final name = p.basename(path);
    return Attachment(filename: name, mimeType: attachmentMime(name, bytes), bytes: bytes);
  } on FileSystemException catch (e) {
    logFailure("clipboard", "pasted file unreadable", e.osError ?? e.message);
    return null;
  }
}

Attachment? _fromBytes(Map<Object?, Object?> entry) {
  final bytes = entry["bytes"];
  if (bytes is! Uint8List) return null;
  final name = entry["name"] as String? ?? "pasted";
  return Attachment(
      filename: name,
      mimeType: attachmentMime(name, bytes, declared: entry["mime"] as String?),
      bytes: bytes);
}
