import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "../../../domain/workspace.dart";

/// Writes a zip of artifact files to a fresh temporary directory and returns
/// where it landed. The mirror-side half of opening a remote artifact: the
/// bytes came off the sync channel, and every platform viewer — `file://` on
/// the desktop, the loopback HTTP server on Android — is the one the local
/// artifact already had, which is why this writes a real directory rather
/// than adding a second viewer over memory.
///
/// Member names came from wherever the zip was made, so each goes through
/// [safeRelativePath] before joining the temp root — a name like
/// `../x.html` lands flattened inside the directory instead of outside it.
Future<String> unzipRemoteArtifact(Uint8List bytes) async {
  final dir = await Directory.systemTemp.createTemp("entoli-artifact");
  for (final member in ZipDecoder().decodeBytes(bytes)) {
    if (member.isDirectory) continue;
    final target =
        "${dir.path}/${safeRelativePath(fileSystemIo, member.name)}";
    final file = File(target);
    await file.create(recursive: true);
    await file.writeAsBytes(member.readBytes() ?? Uint8List(0));
  }
  return dir.path;
}