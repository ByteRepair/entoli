import "dart:async";
import "dart:io";

import "package:agent_chat/data/local/file_rootfs_store.dart";
import "package:agent_chat/domain/rootfs.dart";
import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "fake_network.dart";

/// Against the machine's real `tar`, in one test, for the reason
/// `voice_model_store_test.dart` is: what is worth pinning is the shape of
/// what lands on disk — the marker that says a Linux is whole, the nothing a
/// cancelled download leaves, and the symlinks and execute bits that are why
/// this shells out to `tar` at all. The network itself is [FakeNetwork], so a
/// suite run binds no port.
void main() {
  late Directory root;
  late Directory source;
  late FakeNetwork net;
  late List<int> tarball;

  setUp(() async {
    root = await Directory.systemTemp.createTemp("rootfs-store");
    source = await Directory.systemTemp.createTemp("rootfs-source");

    // A rootfs in miniature: something to run, and a name that is a link to it.
    final bin = Directory(p.join(source.path, "bin"))..createSync(recursive: true);
    File(p.join(bin.path, "busybox")).writeAsStringSync("#!/bin/sh\necho hi\n");
    await Process.run("chmod", ["+x", p.join(bin.path, "busybox")]);
    Link(p.join(bin.path, "sh")).createSync("busybox");
    final archive = p.join(root.path, "fixture.tar.gz");
    await Process.run("tar", ["-czf", archive, "-C", source.path, "bin"]);
    tarball = File(archive).readAsBytesSync();
    File(archive).deleteSync();

    net = FakeNetwork.inHalves({
      "/rootfs.tar.gz": tarball,
      "/rubbish": List.filled(64, 7),
    });
  });

  tearDown(() async {
    net.hold?.complete();
    await root.delete(recursive: true);
    await source.delete(recursive: true);
  });

  String url(String path) => net.url(path);

  Rootfs distro({String? path, String? sha}) => Rootfs(
        id: "testix",
        name: "Testix",
        version: "1.0",
        packageManager: "tpk",
        images: {
          "x86_64": RootfsImage(
            arch: "x86_64",
            url: url(path ?? "/rootfs.tar.gz"),
            bytes: tarball.length,
            sha256: sha ?? sha256.convert(tarball).toString(),
          ),
        },
      );

  FileRootfsStore storeIn(
          {Future<ProcessResult> Function(String, String)? tar}) =>
      tar == null
          ? FileRootfsStore(p.join(root.path, "rootfs"), client: net)
          : FileRootfsStore(p.join(root.path, "rootfs"),
              client: net, tar: tar);

  test("a finished install is unpacked, marked whole, and the tarball is gone",
      () async {
    final store = storeIn();
    final rootfs = distro();

    await store.install(rootfs, abi: "x86_64").drain<void>();

    expect(await store.installed(), {"testix"});
    final dir = (await store.directoryOf(rootfs))!;
    expect(store.directoryOfSync("testix"), dir);
    expect(File(p.join(dir, "_rootfs.tar.gz")).existsSync(), isFalse);
  });

  test("what tar writes and Dart cannot: the execute bit, and a symlink that is "
      "still a link", () async {
    final store = storeIn();

    await store.install(distro(), abi: "x86_64").drain<void>();

    final dir = store.directoryOfSync("testix")!;
    final busybox = File(p.join(dir, "bin", "busybox"));
    expect(busybox.statSync().mode & 0x49, isNot(0),
        reason: "a busybox nothing may execute is a Linux that cannot start");
    expect(Link(p.join(dir, "bin", "sh")).targetSync(), "busybox");
  });

  test("it says how far along it is, and that unpacking is a phase of its own",
      () async {
    final seen = await storeIn().install(distro(), abi: "x86_64").toList();

    expect(seen.first.received, 0);
    expect(seen.last.unpacking, isTrue);
    expect(seen.map((p) => p.total).toSet(), {tarball.length});
  });

  test("a tarball that is not the one that was checked installs nothing",
      () async {
    final store = storeIn();

    await expectLater(
      store.install(distro(path: "/rubbish"), abi: "x86_64").drain<void>(),
      throwsA(isA<StateError>()),
    );

    expect(await store.installed(), isEmpty);
    expect(Directory(p.join(root.path, "rootfs", "testix")).existsSync(), isFalse);
  });

  test("a cancelled download leaves nothing behind", () async {
    final store = storeIn();
    net.hold = Completer<void>();

    final sub = store.install(distro(), abi: "x86_64").listen(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await store.installed(), isEmpty);
    expect(store.directoryOfSync("testix"), isNull);
  });

  test("an architecture the distribution has no build for is refused rather "
      "than fetched", () async {
    await expectLater(
      storeIn().install(distro(), abi: "armeabi-v7a").drain<void>(),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test("a failed unpack is not an install", () async {
    final store = storeIn(
        tar: (archive, into) async => ProcessResult(0, 2, "", "tar: broken"));

    await expectLater(
      store.install(distro(), abi: "x86_64").drain<void>(),
      throwsA(isA<ProcessException>()),
    );

    expect(await store.installed(), isEmpty);
  });

  test("what is installed is read off the disk, so nothing has to be recorded "
      "beside it", () async {
    final store = storeIn();
    Directory(p.join(root.path, "rootfs", "handmade")).createSync(recursive: true);
    File(p.join(root.path, "rootfs", "handmade", ".complete")).writeAsStringSync("");
    Directory(p.join(root.path, "rootfs", "half")).createSync(recursive: true);

    expect(await store.installed(), {"handmade"});
  });

  test("deleting takes the whole of it", () async {
    final store = storeIn();
    final rootfs = distro();
    await store.install(rootfs, abi: "x86_64").drain<void>();

    await store.delete(rootfs);

    expect(await store.installed(), isEmpty);
  });
}
