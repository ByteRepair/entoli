import "dart:convert";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_idb.dart";
import "package:fs_shim/fs_memory.dart";

import "package:agent_chat/data/web/guest_files.dart";
import "package:agent_chat/data/web/ninep.dart";

/// Enough of the guest kernel's half of 9P2000.L to drive the server the way
/// Linux does.
class _Client {
  _Client(this.server);

  final GuestFileServer server;
  var _tag = 0;
  var _nextFid = 1;

  Future<P9Reader> call(int type, void Function(P9Writer) body) async {
    final w = P9Writer();
    body(w);
    final reply = await server.handle(w.message(type, ++_tag));
    final r = P9Reader(reply)..offset = 4;
    final got = r.u8();
    r.u16();
    if (got == P9.lerror) throw _Errno(r.u32());
    expect(got, type + 1);
    return r;
  }

  Future<int> attach() async {
    await call(P9.version, (w) => w..u32(65536)..str("9P2000.L"));
    final fid = _nextFid++;
    await call(P9.attach, (w) => w
      ..u32(fid)
      ..u32(P9.noFid)
      ..str("root")
      ..str("")
      ..u32(0));
    return fid;
  }

  Future<int> walk(int from, List<String> names) async {
    final fid = _nextFid++;
    final r = await call(P9.walk, (w) {
      w
        ..u32(from)
        ..u32(fid)
        ..u16(names.length);
      names.forEach(w.str);
    });
    if (r.u16() != names.length) throw const _Errno(Errno.noent);
    return fid;
  }

  Future<void> open(int fid, int flags) =>
      call(P9.lopen, (w) => w..u32(fid)..u32(flags));

  Future<void> create(int dir, String name, {int mode = 0x1a4}) =>
      call(P9.lcreate, (w) => w
        ..u32(dir)
        ..str(name)
        ..u32(0x41)
        ..u32(mode)
        ..u32(0));

  Future<void> write(int fid, int offset, String text) =>
      call(P9.write, (w) {
        final data = utf8.encode(text);
        w
          ..u32(fid)
          ..u64(offset)
          ..u32(data.length)
          ..data(data);
      });

  Future<String> read(int fid, {int offset = 0, int count = 4096}) async {
    final r = await call(P9.read, (w) => w..u32(fid)..u64(offset)..u32(count));
    return utf8.decode(r.data(r.u32()));
  }

  Future<List<String>> list(int fid) async {
    await open(fid, 0);
    final names = <String>[];
    var offset = 0;
    for (;;) {
      final r = await call(P9.readdir, (w) => w..u32(fid)..u64(offset)..u32(200));
      final end = r.u32() + r.offset;
      if (end == r.offset) return names;
      while (r.offset < end) {
        r.data(13);
        offset = r.u64();
        r.u8();
        names.add(r.str());
      }
    }
  }

  Future<int> mode(int fid) async {
    final r = await call(P9.getattr, (w) => w..u32(fid)..u64(0x7ff));
    r.u64();
    r.data(13);
    return r.u32();
  }

  Future<void> clunk(int fid) => call(P9.clunk, (w) => w.u32(fid));
}

class _Errno implements Exception {
  const _Errno(this.errno);
  final int errno;
  @override
  String toString() => "errno $errno";
}

Matcher _fails(int errno) =>
    throwsA(isA<_Errno>().having((e) => e.errno, "errno", errno));

void main() {
  late FileSystem fs;
  late GuestFileServer server;
  late _Client client;
  const root = "/entoli";
  const workspace = "$root/projects/default/workspace";

  setUp(() async {
    fs = newFileSystemMemory()
        .withIdbOptions(options: FileSystemIdbOptions.pageDefault);
    await fs.directory("$workspace/chats/c1").create(recursive: true);
    await fs
        .file("$root/projects/default/skills-bundled/pdf/SKILL.md")
        .create(recursive: true);
    await fs.file("$root/projects/default/chats/c1/conv.jsonl")
        .create(recursive: true);
    await fs.file("$root/settings.json").writeAsString("{}");
    server = GuestFileServer(fs,
        root: root, modes: GuestModes(fs, "$root/guest-modes.json"));
    client = _Client(server);
  });

  test("the guest sees the workspaces and skills, and none of the app's own",
      () async {
    final top = await client.attach();
    expect(await client.list(await client.walk(top, [])), [".", "..", "projects"]);
    final project = await client.walk(top, ["projects", "default"]);
    expect(await client.list(project),
        unorderedEquals([".", "..", "skills-bundled", "workspace"]));
    await expectLater(client.walk(top, ["settings.json"]), _fails(Errno.noent));
    await expectLater(
        client.walk(top, ["projects", "default", "chats"]), _fails(Errno.noent));
  });

  test("a file written by a command is the app's file", () async {
    final top = await client.attach();
    final chat = await client.walk(
        top, ["projects", "default", "workspace", "chats", "c1"]);
    final dir = await client.walk(chat, []);
    await client.create(dir, "notes.txt");
    await client.write(dir, 0, "hello world");
    await client.write(dir, 6, "there");
    await client.clunk(dir);
    expect(await fs.file("$workspace/chats/c1/notes.txt").readAsString(),
        "hello there");

    final again = await client.walk(chat, ["notes.txt"]);
    await client.open(again, 0);
    expect(await client.read(again, offset: 6), "there");
  });

  test("a write the app made between commands is what the next read sees",
      () async {
    final top = await client.attach();
    await fs.file("$workspace/a.txt").writeAsString("one");
    final file = await client.walk(top, ["projects", "default", "workspace", "a.txt"]);
    await client.open(file, 0);
    expect(await client.read(file), "one");
    await fs.file("$workspace/a.txt").writeAsString("two!");
    expect(await client.read(file), "two!");
  });

  test("skills are read-only", () async {
    final top = await client.attach();
    final skill = await client.walk(
        top, ["projects", "default", "skills-bundled", "pdf"]);
    await expectLater(client.create(skill, "x"), _fails(Errno.rofs));
    final md = await client.walk(skill, ["SKILL.md"]);
    await expectLater(client.open(md, 1), _fails(Errno.rofs));
    expect(await client.mode(md) & 0x1ff, 0x124, reason: "r--r--r--");
  });

  test("O_TRUNC empties the file", () async {
    final top = await client.attach();
    await fs.file("$workspace/t").writeAsString("long contents");
    final file = await client.walk(top, ["projects", "default", "workspace", "t"]);
    await client.open(file, 0x201);
    await client.write(file, 0, "x");
    await client.clunk(file);
    expect(await fs.file("$workspace/t").readAsString(), "x");
  });

  test("a rename over an existing file replaces it, and the open fid follows",
      () async {
    final top = await client.attach();
    final ws = await client.walk(top, ["projects", "default", "workspace"]);
    final lock = await client.walk(ws, []);
    await client.create(lock, "index.lock");
    await client.write(lock, 0, "new");
    await fs.file("$workspace/index").writeAsString("old");
    await client.call(P9.renameat, (w) => w
      ..u32(ws)
      ..str("index.lock")
      ..u32(ws)
      ..str("index"));
    await client.write(lock, 3, "er");
    await client.clunk(lock);
    expect(await fs.file("$workspace/index").readAsString(), "newer");
    expect(await fs.file("$workspace/index.lock").exists(), isFalse);
  });

  test("a mode set by chmod survives a new server over the same files",
      () async {
    final top = await client.attach();
    final ws = await client.walk(top, ["projects", "default", "workspace"]);
    final script = await client.walk(ws, []);
    await client.create(script, "run.sh");
    await client.call(P9.setattr, (w) => w
      ..u32(script)
      ..u32(0x1)
      ..u32(0x1ed)
      ..u32(0)
      ..u32(0)
      ..u64(0)
      ..u64(0)
      ..u64(0)
      ..u64(0)
      ..u64(0));
    await server.modes!.flush();

    final modes = GuestModes(fs, "$root/guest-modes.json");
    await modes.load();
    final fresh = _Client(GuestFileServer(fs, root: root, modes: modes));
    final file = await fresh.walk(
        await fresh.attach(), ["projects", "default", "workspace", "run.sh"]);
    expect(await fresh.mode(file) & 0x1ff, 0x1ed);
  });

  test("directories are made, refused while full, and removed when empty",
      () async {
    final top = await client.attach();
    final ws = await client.walk(top, ["projects", "default", "workspace"]);
    await client.call(P9.mkdir, (w) => w..u32(ws)..str("d")..u32(0x1ed)..u32(0));
    final d = await client.walk(ws, ["d"]);
    await client.create(await client.walk(d, []), "f");
    Future<void> rmdir() => client.call(
        P9.unlinkat, (w) => w..u32(ws)..str("d")..u32(0x200));
    await expectLater(rmdir(), _fails(Errno.notempty));
    await client.call(P9.unlinkat, (w) => w..u32(d)..str("f")..u32(0));
    await rmdir();
    expect(await fs.directory("$workspace/d").exists(), isFalse);
  });

  test("a symlink reads back as one", () async {
    final top = await client.attach();
    final ws = await client.walk(top, ["projects", "default", "workspace"]);
    await client.call(P9.symlink, (w) => w..u32(ws)..str("l")..str("target")..u32(0));
    final link = await client.walk(ws, ["l"]);
    final r = await client.call(P9.readlink, (w) => w.u32(link));
    expect(r.str(), "target");
    expect(await client.mode(link) & 0xf000, 0xa000);
  });

  test("a readdir split across replies lists every entry once", () async {
    final top = await client.attach();
    for (var i = 0; i < 30; i++) {
      await fs.file("$workspace/file-$i").create();
    }
    final ws = await client.walk(top, ["projects", "default", "workspace"]);
    final names = await client.list(ws);
    expect(names.where((n) => n.startsWith("file-")).toSet(), hasLength(30));
    expect(names.length, names.toSet().length);
  });

  test("replies keep the guest's tags", () async {
    final reply = await server.handle(
        (P9Writer()..u32(8192)..str("9P2000.L")).message(P9.version, 0xbeef));
    final r = P9Reader(Uint8List.fromList(reply))..offset = 5;
    expect(r.u16(), 0xbeef);
  });
}
