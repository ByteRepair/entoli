import "dart:async";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:path/path.dart" as p;
import "package:http/http.dart" as http;

import "../download.dart";
import "../../domain/download.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "tree_ops.dart";

/// A downloaded Linux in a directory of its own, outside the data directory —
/// see [RootfsStore] for why that matters.
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

  @override
  Future<Set<String>> installed() => markedDirs(root, _marker);

  /// A rootfs that hosted a session contains proot's mode-0000 bind stubs,
  /// which `dart:io` cannot list — see `tree_ops.dart` — so the removal goes
  /// through [removeTree] rather than a plain recursive delete.
  @override
  Future<void> delete(Rootfs rootfs) async {
    final err = await removeTree(directoryFor(rootfs.id));
    if (err != null) {
      throw ProcessException("rm", ["-rf", directoryFor(rootfs.id)], err);
    }
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

          final digest =
              await run.fetchSha256(url: image.url, to: archive, total: image.bytes);
          if (run.cancelled) return;
          // Before a byte of it is unpacked, let alone run. Everything in here
          // becomes a program this device will execute, so arriving is not the
          // same as being what was asked for.
          if (digest != image.sha256) {
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
  /// `runTar` in `tree_ops` handles finding it on `PATH` or at
  /// `/system/bin/tar`, so this is one call through it.
  static Future<ProcessResult> _systemTar(String archive, String into) =>
      runTar(["-xzf", archive, "-C", into]);
}

/// The ids under [root] whose directory holds [marker] — read off the disk
/// rather than the catalog, so an entry the catalog has since renamed still
/// shows as taking up the space it takes up.
Future<Set<String>> markedDirs(String root, String marker) async {
  final dir = Directory(root);
  if (!await dir.exists()) return const {};
  final out = <String>{};
  await for (final entry in dir.list()) {
    if (entry is Directory && await File(p.join(entry.path, marker)).exists()) {
      out.add(p.basename(entry.path));
    }
  }
  return out;
}

extension DownloadRunSha256 on DownloadRun {
  /// [fetch] one file and answer its SHA-256 in hex, hashed on the way past
  /// rather than by reading back what may be gigabytes.
  Future<String> fetchSha256(
      {required String url, required String to, int? total, int done = 0}) async {
    report(DownloadProgress(received: done, total: total ?? 0));
    final hash = _Sha256Sink();
    final hashing = sha256.startChunkedConversion(hash);
    await fetch(url: url, to: to, total: total, done: done, watch: hashing);
    hashing.close();
    return "${hash.digest}";
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
