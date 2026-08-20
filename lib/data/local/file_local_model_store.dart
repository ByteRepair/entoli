import "dart:io";

import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;

import "../../domain/download.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";
import "../download.dart";

/// A downloaded model in a directory of its own, outside the data directory —
/// see [LocalModelStore] for why that matters. `dart:io` rather than the
/// config's `FileSystem` for the reason `FileRootfsStore` is: what reads this
/// file is a subprocess with a path, not the app.
class FileLocalModelStore extends LocalModelStore {
  const FileLocalModelStore(this.root);

  /// `<cacheDir>/llm`, holding one directory per installed model.
  final String root;

  /// Written last, and the whole of what "installed" means: a directory a
  /// download was killed halfway through has a partial file in it and no
  /// marker.
  static const _marker = ".complete";

  /// The weights, under the model's own directory rather than the name they
  /// were published under. The publisher's name is in the URL and nowhere the
  /// app has to keep in step with it.
  static const _weights = "model.gguf";

  String directoryFor(String id) => p.join(root, id);

  String _fileFor(LocalModel model) => p.join(directoryFor(model.id), _weights);

  @override
  String? fileOfSync(LocalModel model) =>
      File(p.join(directoryFor(model.id), _marker)).existsSync()
          ? _fileFor(model)
          : null;

  /// Read off the disk rather than off the catalog, so a model the catalog has
  /// since renamed still shows as taking up the space it takes up.
  @override
  Future<Set<String>> installed() async {
    final dir = Directory(root);
    if (!await dir.exists()) return const {};
    final out = <String>{};
    await for (final entry in dir.list()) {
      if (entry is! Directory) continue;
      if (await File(p.join(entry.path, _marker)).exists()) {
        out.add(p.basename(entry.path));
      }
    }
    return out;
  }

  @override
  Future<void> delete(LocalModel model) async {
    final dir = Directory(directoryFor(model.id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// One file, checked and kept where it landed. The fetching and the giving
  /// up are [DownloadRun]'s; what is left here is the checksum and the marker.
  @override
  Stream<DownloadProgress> install(LocalModel model) => DownloadRun(
        discard: () => delete(model),
        run: (run) async {
          // Whatever an earlier attempt left: a partial file under a name we
          // are about to write, which is worse than starting again.
          await delete(model);
          final dir = Directory(directoryFor(model.id))
            ..createSync(recursive: true);

          run.report(DownloadProgress(received: 0, total: model.bytes));
          // Hashed on the way past rather than by reading the file back: it is
          // the same bytes, and this is the largest file the app fetches.
          final hash = _Sha256Sink();
          final hashing = sha256.startChunkedConversion(hash);
          await run.fetch(
            url: model.url,
            to: _fileFor(model),
            total: model.bytes,
            watch: hashing,
          );
          hashing.close();
          if (run.cancelled) return;
          // A gigabyte over somebody's mobile data, and the publisher already
          // says what it should come to. Weights are not a program, so this is
          // not the check a rootfs gets — it is the check that the download
          // finished, and arrived from the model it claims to be.
          if ("${hash.digest}" != model.sha256) {
            throw StateError(
              "The download did not match what ${model.name} was checked to "
              "be, so nothing was kept.",
            );
          }
          await File(p.join(dir.path, _marker)).writeAsString("");
        },
      ).stream;
}

/// Where the hash of the download lands. `package:convert` has one of these and
/// is not a dependency for four lines.
class _Sha256Sink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
