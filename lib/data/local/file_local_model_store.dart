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
import "gguf.dart";

/// A downloaded model in a directory of its own, outside the data directory —
/// see [LocalModelStore] for why that matters. `dart:io` rather than the
/// config's `FileSystem` for the reason `FileRootfsStore` is: what reads this
/// file is a subprocess with a path, not the app.
///
/// Each directory holds the weights, a record of what they are and where they
/// came from, and the marker, written last. The record is what lists it: the
/// catalog is only where some of them were fetched from.
class FileLocalModelStore extends LocalModelStore {
  FileLocalModelStore(this.root, {this.client});

  /// The client downloads go through. Injected only by the tests, which have
  /// no socket to reach.
  final http.Client? client;

  /// `<cacheDir>/llm`, holding one directory per installed model.
  final String root;

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

  /// The weights, under the model's own directory rather than the name they
  /// were published under.
  static const _weights = "model.gguf";

  static const _record = "model.json";

  String directoryFor(String id) => p.join(root, id);

  String _fileFor(String id) => p.join(directoryFor(id), _weights);

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

  /// The record, or one written from the file's header for a directory that
  /// has none — what a build before records downloaded.
  DownloadedModel? _read(String id) {
    final file = _fileFor(id);
    final record = File(p.join(directoryFor(id), _record));
    try {
      if (record.existsSync()) {
        return DownloadedModel.fromJson(jsonDecode(record.readAsStringSync()), file: file);
      }
      final model = _describe(id, file);
      record.writeAsStringSync(jsonEncode(model.toJson()));
      return model;
    } catch (e) {
      logFailure("llm", "could not read the downloaded model $id", e);
      return null;
    }
  }

  DownloadedModel _describe(String id, String file, [LocalModel? from]) {
    final facts = readGgufFacts(file);
    return DownloadedModel(
      id: id,
      name: (from?.name.isNotEmpty ?? false ? from!.name : null) ?? facts.name ?? id,
      file: file,
      bytes: File(file).lengthSync(),
      quantisation: facts.quantisation,
      contextLength: facts.contextLength,
      kvBytesPerToken: facts.kvBytesPerToken,
      parameters: from?.parameters,
      licence: from?.licence,
      url: from?.url,
    );
  }

  @override
  Future<void> delete(String id) async {
    _downloaded = downloadedSync().where((m) => m.id != id).toList();
    final dir = Directory(directoryFor(id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// One file, checked and described and kept where it landed. The fetching
  /// and the giving up are [DownloadRun]'s.
  @override
  Stream<DownloadProgress> install(LocalModel model) => DownloadRun(
        client: client,
        discard: () => delete(model.id),
        run: (run) async {
          // Whatever an earlier attempt left: a partial file under a name we
          // are about to write, which is worse than starting again.
          await delete(model.id);
          final dir = Directory(directoryFor(model.id))
            ..createSync(recursive: true);
          final file = _fileFor(model.id);

          final digest =
              await run.fetchSha256(url: model.url, to: file, total: model.bytes);
          if (run.cancelled) return;
          // A gigabyte over somebody's mobile data, and the publisher already
          // says what it should come to. Weights are not a program, so this is
          // not the check a rootfs gets — it is the check that the download
          // finished, and arrived from the model it claims to be.
          final expected = model.sha256;
          if (expected != null && digest != expected.toLowerCase()) {
            throw StateError(
              "The download did not match what ${model.name} was checked to "
              "be, so nothing was kept.",
            );
          }
          final DownloadedModel downloaded;
          try {
            downloaded = _describe(model.id, file, model);
          } on FormatException catch (e) {
            throw StateError("${model.name} is not a model this app can run: ${e.message}.");
          }
          await File(p.join(dir.path, _record)).writeAsString(jsonEncode(downloaded.toJson()));
          await File(p.join(dir.path, _marker)).writeAsString("");
          _downloaded = [...downloadedSync().where((m) => m.id != model.id), downloaded];
        },
      ).stream;
}
