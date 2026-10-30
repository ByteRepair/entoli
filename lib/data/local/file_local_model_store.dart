import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;
import "package:http/http.dart" as http;

import "../../core/log.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../../domain/download.dart";
import "../download.dart";
import "file_rootfs_store.dart" show DownloadRunSha256;
import "model_format.dart";

/// A downloaded model in a directory of its own, outside the data directory —
/// see [LocalModelStore] for why that matters.
///
/// Each directory holds the model's files, a record of what they are and where
/// they came from, and the marker, written last. The record is what lists it:
/// the catalog is only where some of them were fetched from. What the files
/// mean is [format]'s; this class fetches and checks them.
class FileLocalModelStore extends LocalModelStore {
  FileLocalModelStore(this.root, {required this.format, this.client});

  /// The client downloads go through. Injected only by the tests, which have
  /// no socket to reach.
  final http.Client? client;

  /// `<cacheDir>/llm`, holding one directory per installed model.
  final String root;

  final ModelFormat format;

  /// What is on disk, read once and then kept in step by [install] and
  /// [delete], the one class that owns both.
  ///
  /// It is asked every time the provider list is built, and that list is built
  /// for every model a turn resolves — so without this a turn is a directory
  /// walk on the isolate drawing the UI.
  List<DownloadedModel>? _downloaded;

  /// Written last, and the whole of what "installed" means: a directory a
  /// download was killed halfway through has a partial file in it and no
  /// marker.
  static const _marker = ".complete";

  static const _record = "model.json";

  String directoryFor(String id) => p.join(root, id);

  @override
  List<DownloadedModel> downloadedSync() => _downloaded ??= _scan();

  @override
  Future<Set<String>> installed() async {
    _downloaded = null;
    return {for (final model in downloadedSync()) model.id};
  }

  List<DownloadedModel> _scan() {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    return [
      for (final entry in dir.listSync()..sort((a, b) => a.path.compareTo(b.path)))
        if (entry is Directory && File(p.join(entry.path, _marker)).existsSync())
          ?_read(p.basename(entry.path)),
    ];
  }

  /// The record, or one written from the files themselves for a directory that
  /// has none — what a build before records downloaded.
  DownloadedModel? _read(String id) {
    final directory = directoryFor(id);
    final record = File(p.join(directory, _record));
    try {
      if (record.existsSync()) {
        return DownloadedModel.fromJson(jsonDecode(record.readAsStringSync()),
            file: format.entry(directory));
      }
      final model = format.describe(id, directory);
      record.writeAsStringSync(jsonEncode(model.toJson()));
      return model;
    } catch (e) {
      logFailure("llm", "could not read the downloaded model $id", e);
      return null;
    }
  }

  @override
  Future<void> delete(String id) async {
    _downloaded = downloadedSync().where((m) => m.id != id).toList();
    final dir = Directory(directoryFor(id));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// Every file, checked, then described and kept where it landed. The
  /// fetching and the giving up are [DownloadRun]'s.
  @override
  Stream<DownloadProgress> install(LocalModel model) => DownloadRun(
        client: client,
        discard: () => delete(model.id),
        run: (run) async {
          // Whatever an earlier attempt left: a partial file under a name we
          // are about to write, which is worse than starting again.
          await delete(model.id);
          final directory = directoryFor(model.id);
          Directory(directory).createSync(recursive: true);

          final total = model.bytes;
          var done = 0;
          for (final file in model.files) {
            final to = p.join(directory, file.path);
            Directory(p.dirname(to)).createSync(recursive: true);
            final digest = await run.fetchSha256(
                url: file.url, to: to, total: total, done: done);
            if (run.cancelled) return;
            // A gigabyte over somebody's mobile data, and the publisher already
            // says what it should come to. Weights are not a program, so this
            // is not the check a rootfs gets — it is the check that the download
            // finished, and arrived from the model it claims to be.
            final expected = file.sha256;
            if (expected != null && digest != expected.toLowerCase()) {
              throw StateError(
                "The download did not match what ${model.name} was checked to "
                "be, so nothing was kept.",
              );
            }
            done += file.bytes ?? await File(to).length();
          }

          final DownloadedModel downloaded;
          try {
            downloaded = format.describe(model.id, directory, model);
          } on FormatException catch (e) {
            throw StateError("${model.name} is not a model this app can run: ${e.message}.");
          }
          await File(p.join(directory, _record))
              .writeAsString(jsonEncode(downloaded.toJson()));
          await File(p.join(directory, _marker)).writeAsString("");
          _downloaded = [...downloadedSync().where((m) => m.id != model.id), downloaded];
        },
      ).stream;
}
