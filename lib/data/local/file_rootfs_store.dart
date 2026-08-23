import "dart:async";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;
import "package:http/http.dart" as http;

import "../download.dart";
import "../../domain/download.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";

/// A downloaded Linux in a directory of its own, outside the data directory —
/// see [RootfsStore] for why that matters. `dart:io` rather than the config's
/// `FileSystem` for the reason `LocalShell` is: this side of the conditional
/// import is the only one that can run what is in there.
class FileRootfsStore extends RootfsStore {
  FileRootfsStore(this.root, {this.tar = _systemTar, this.client});

  /// The client downloads go through. Injected only by the tests, which have
  /// no socket to reach.
  final http.Client? client;

  /// `<cacheDir>/rootfs`, holding one directory per installed distribution.
  final String root;

  /// What unpacks the tarball, and the one thing here that is not Dart's.
  /// A rootfs is symlinks, execute bits and the odd hard link — `/bin/ls` is a
  /// link to busybox and busybox without its execute bit is a Linux that cannot
  /// run its first command — and Dart can write none of the three. The system's
  /// own `tar` writes all of them, which makes it the right tool rather than a
  /// shortcut. Injected so a test can watch what it was asked to do.
  final Future<ProcessResult> Function(String archive, String into) tar;

  /// Written last, and the whole of what "installed" means: a directory a
  /// download was killed halfway through has files in it and no marker.
  static const _marker = ".complete";

  String directoryFor(String id) => p.join(root, id);

  @override
  Future<String?> directoryOf(Rootfs rootfs) async {
    final dir = directoryFor(rootfs.id);
    return File(p.join(dir, _marker)).exists().then((ok) => ok ? dir : null);
  }

  @override
  String? directoryOfSync(String id) {
    final dir = directoryFor(id);
    return File(p.join(dir, _marker)).existsSync() ? dir : null;
  }

  /// Read off the disk rather than off the catalog, so a distribution the
  /// catalog has since renamed still shows as taking up the space it takes up.
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
  Future<void> delete(Rootfs rootfs) async {
    final dir = Directory(directoryFor(rootfs.id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// One tarball, checked and then unpacked. The fetching and the giving up are
  /// [DownloadRun]'s; what is left here is the checksum, which is the thing
  /// this download has that no other one does.
  @override
  Stream<DownloadProgress> install(Rootfs rootfs, {required String abi}) => DownloadRun(
        client: client,
        discard: () => delete(rootfs),
        run: (run) async {
          final image = rootfs.imageFor(abi);
          if (image == null) {
            throw UnsupportedError("${rootfs.name} has no build for $abi.");
          }
          // Whatever an earlier attempt left: files under a name we are about to
          // write, which is worse than starting again.
          await delete(rootfs);
          final dir = Directory(directoryFor(rootfs.id))..createSync(recursive: true);
          final archive = p.join(dir.path, "_rootfs.tar.gz");

          run.report(DownloadProgress(received: 0, total: image.bytes));
          // Hashed on the way past rather than by reading the file back: it is
          // the same bytes, and a phone reads them slowly.
          final hash = _Sha256Sink();
          final hashing = sha256.startChunkedConversion(hash);
          await run.fetch(
            url: image.url,
            to: archive,
            total: image.bytes,
            watch: hashing,
          );
          hashing.close();
          if (run.cancelled) return;
          // Before a byte of it is unpacked, let alone run. Everything in here
          // becomes a program this device will execute, so arriving is not the
          // same as being what was asked for.
          if ("${hash.digest}" != image.sha256) {
            throw StateError(
              "The download did not match what ${rootfs.name} ${rootfs.version} was "
              "checked to be, so nothing was installed.",
            );
          }

          run.report(DownloadProgress(
              received: image.bytes, total: image.bytes, unpacking: true));
          final result = await tar(archive, dir.path);
          if (run.cancelled) return;
          if (result.exitCode != 0) {
            throw ProcessException("tar", const [], "${result.stderr}".trim(),
                result.exitCode);
          }
          await File(archive).delete();
          await File(p.join(dir.path, _marker)).writeAsString("");
        },
      ).stream;

  /// Android's `tar` is toybox's, and `-z` is the one thing this needs of it.
  /// The absolute path is the fallback for a device whose `PATH` does not name
  /// it, the same two-step `LocalShell` takes to find a shell.
  static Future<ProcessResult> _systemTar(String archive, String into) async {
    for (final tar in const ["tar", "/system/bin/tar"]) {
      try {
        return await Process.run(tar, ["-xzf", archive, "-C", into]);
      } on ProcessException {
        continue;
      }
    }
    throw const ProcessException(
        "tar", [], "This device has no tar to unpack a Linux with.");
  }
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
