import "dart:async";
import "dart:io";
import "dart:isolate";

import "package:archive/archive.dart";
import "package:path/path.dart" as p;
import "package:http/http.dart" as http;

import "../download.dart";
import "../../domain/download.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../../domain/workspace.dart";

/// Voice models in a directory of their own, outside the data directory — see
/// [VoiceModelStore] for why that matters.
class FileVoiceModelStore extends VoiceModelStore {
  FileVoiceModelStore(this.root, {this.client});

  /// The client downloads go through. Injected only by the tests, which have
  /// no socket to reach.
  final http.Client? client;

  /// `<cacheDir>/models`. Holds `stt/` and `tts/` under it.
  final String root;

  /// Written last, and the whole of what "installed" means: a directory a
  /// download was killed halfway through has files in it and no marker, so a
  /// reload sees it for what it is rather than loading half a model.
  static const _marker = ".complete";

  String directoryFor(VoiceModel model) => p.join(root, model.folder, model.id);

  @override
  Future<String?> directoryOf(VoiceModel model) async {
    final dir = directoryFor(model);
    return File(p.join(dir, _marker)).exists().then((ok) => ok ? dir : null);
  }

  /// Read off the disk rather than off the catalog: what is installed is a
  /// directory with a marker in it, and a model the catalog has since renamed
  /// still takes up the space it takes up.
  @override
  Future<Set<String>> installed() async {
    final out = <String>{};
    for (final folder in voiceFolders) {
      final dir = Directory(p.join(root, folder));
      if (!dir.existsSync()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        if (File(p.join(entry.path, _marker)).existsSync()) {
          out.add(p.basename(entry.path));
        }
      }
    }
    return out;
  }

  @override
  Future<void> delete(VoiceModel model) async {
    final dir = Directory(directoryFor(model));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// Two to four files, or one archive, into the model's own directory. The
  /// fetching and the giving up are [DownloadRun]'s; what is left here is the
  /// bz2 an archive has to be put through and the marker that says the model is
  /// whole.
  @override
  Stream<DownloadProgress> install(VoiceModel model) => DownloadRun(
        client: client,
        discard: () => delete(model),
        run: (run) async {
          // Whatever an earlier attempt left: partial files under a name we are
          // about to write, which is worse than starting again.
          await delete(model);
          final dir = Directory(directoryFor(model))..createSync(recursive: true);

          var received = 0;
          final total = model.bytes;
          run.report(DownloadProgress(received: 0, total: total));

          for (final download in model.downloads) {
            final target = switch (download) {
              VoiceFile(:final path) => p.join(dir.path, path),
              VoiceArchive() => p.join(dir.path, "_archive.tar.bz2"),
            };
            received += await run.fetch(
              url: download.url,
              to: target,
              total: total,
              done: received,
            );
            if (run.cancelled) return;
            if (download is VoiceArchive) {
              run.report(DownloadProgress(
                  received: received, total: total, unpacking: true));
              await _unpackOffThread(target, dir.path);
            }
          }
          if (run.cancelled) return;
          await File(p.join(dir.path, _marker)).writeAsString("");
        },
      ).stream;

  /// Off the UI thread, because bz2 in Dart runs at about 8 MB/s and Kokoro is
  /// a minute of solid CPU. Its own method so that the closure handed to the
  /// isolate captures these two strings and nothing else: written inline in
  /// [install] it drags that method's whole context along, stream controller
  /// included, and an isolate cannot be sent one.
  static Future<void> _unpackOffThread(String archive, String into) =>
      Isolate.run(() => _unpack(archive, into));

  /// bz2 to a tar beside it, then the tar's entries into [into]. Each entry's
  /// first path segment is dropped — these archives hold one top-level
  /// directory named after the model, and keeping it would nest everything one
  /// deeper than the catalog says.
  static void _unpack(String archive, String into) {
    final tarPath = "$archive.tar";
    final input = InputFileStream(archive);
    final output = OutputFileStream(tarPath);
    try {
      BZip2Decoder().decodeStream(input, output);
    } finally {
      input.closeSync();
      output.closeSync();
    }
    // As soon as it is spent: compressed, tar and extracted all at once is
    // near a gigabyte for the largest model, on a phone.
    File(archive).deleteSync();

    final tar = InputFileStream(tarPath);
    try {
      for (final entry in TarDecoder().decodeStream(tar)) {
        final name = _strip(entry.name);
        if (name == null || !entry.isFile) continue;
        final file = File(p.join(into, name));
        file.parent.createSync(recursive: true);
        final sink = OutputFileStream(file.path);
        try {
          entry.writeContent(sink);
        } finally {
          sink.closeSync();
        }
      }
    } finally {
      tar.closeSync();
      File(tarPath).deleteSync();
    }
  }

  /// The entry's path without its top-level directory, or null where it names
  /// nothing under one. What is left goes through [safeRelativePath], which is
  /// the repo's one answer to a path that arrived from outside: a tar entry is
  /// someone else's writing, and it can carry a backslash, a control character
  /// or a name Windows will not take as readily as it can carry `..`.
  static String? _strip(String name) {
    final parts = p.posix.split(name).where((s) => s.isNotEmpty && s != ".").toList();
    if (parts.length < 2) return null;
    return safeRelativePath(p.posix.joinAll(parts.skip(1)));
  }
}
