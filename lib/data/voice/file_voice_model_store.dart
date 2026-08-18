import "dart:async";
import "dart:io";
import "dart:isolate";

import "package:archive/archive.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../../domain/workspace.dart";

/// Voice models in a directory of their own, outside the data directory — see
/// [VoiceModelStore] for why that matters. `dart:io` rather than the config's
/// `FileSystem` for the same reason `LocalShell` is: this side of the
/// conditional import is the only one that has models at all.
class FileVoiceModelStore extends VoiceModelStore {
  FileVoiceModelStore(this.root);

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
    for (final folder in const ["stt", "tts"]) {
      final dir = Directory(p.join(root, folder));
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        if (await File(p.join(entry.path, _marker)).exists()) {
          out.add(p.basename(entry.path));
        }
      }
    }
    return out;
  }

  @override
  Future<void> delete(VoiceModel model) async {
    final dir = Directory(directoryFor(model));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  @override
  Stream<VoiceModelProgress> install(VoiceModel model) {
    final client = http.Client();
    var cancelled = false;
    late StreamController<VoiceModelProgress> out;

    Future<void> run() async {
      // Whatever an earlier attempt left: partial files under a name we are
      // about to write, which is worse than starting again.
      await delete(model);
      final dir = Directory(directoryFor(model))..createSync(recursive: true);

      var received = 0;
      final total = model.bytes;
      out.add(VoiceModelProgress(modelId: model.id, received: 0, total: total));

      for (final download in model.downloads) {
        final target = switch (download) {
          VoiceFile(:final path) => p.join(dir.path, path),
          VoiceArchive() => p.join(dir.path, "_archive.tar.bz2"),
        };
        await Directory(p.dirname(target)).create(recursive: true);
        received = await _fetch(
          client: client,
          url: download.url,
          to: target,
          from: received,
          report: (at) => out.add(
              VoiceModelProgress(modelId: model.id, received: at, total: total)),
          cancelled: () => cancelled,
        );
        if (cancelled) return;
        if (download is VoiceArchive) {
          out.add(VoiceModelProgress(
              modelId: model.id, received: received, total: total, extracting: true));
          await _unpackOffThread(target, dir.path);
        }
      }
      if (cancelled) return;
      await File(p.join(dir.path, _marker)).writeAsString("");
    }

    out = StreamController<VoiceModelProgress>(
      onListen: () => run().then(
        (_) async {
          // Cancelling closes the stream from the other end, so there is
          // nobody left to tell — only the half-written directory to remove.
          if (cancelled) return delete(model);
          client.close();
          await out.close();
        },
        onError: (Object e) async {
          await delete(model);
          client.close();
          if (!out.isClosed) {
            out.addError(e);
            await out.close();
          }
        },
      ),
      onCancel: () {
        cancelled = true;
        client.close();
      },
    );
    return out.stream;
  }

  /// One file, streamed to disk. Returns the running total across the model's
  /// downloads, which is what the bar is measured against.
  static Future<int> _fetch({
    required http.Client client,
    required String url,
    required String to,
    required int from,
    required void Function(int) report,
    required bool Function() cancelled,
  }) async {
    final response = await client.send(http.Request("GET", Uri.parse(url)));
    if (response.statusCode != 200) {
      throw HttpException("${response.statusCode} for $url");
    }
    final sink = File(to).openWrite();
    var at = from;
    var told = from;
    try {
      // `addStream` rather than `add` per chunk: a phone whose flash is slower
      // than its radio would otherwise queue the difference on the heap, for
      // the length of a 250 MB download.
      await sink.addStream(response.stream.takeWhile((_) => !cancelled()).map((chunk) {
        at += chunk.length;
        // Every chunk would be thousands of reports, and each one rebuilds a
        // notification through five binder calls — for a bar with a hundred
        // pixels to move.
        if (at - told >= _reportEvery) {
          told = at;
          report(at);
        }
        return chunk;
      }));
      report(at);
    } finally {
      await sink.close();
    }
    return at;
  }

  /// How far the bar moves before it is worth saying so.
  static const _reportEvery = 1 << 20;

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
    return safeRelativePath(fileSystemIo, p.posix.joinAll(parts.skip(1)));
  }
}
