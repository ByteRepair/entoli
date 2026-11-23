import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:entoli_chat/core/config.dart";
import "package:entoli_chat/core/migrations.dart";
import "package:entoli_chat/data/chat_share.dart";
import "package:entoli_chat/data/local/file_chat_store.dart";
import "package:entoli_chat/domain/chat_share.dart";
import "package:entoli_chat/domain/models.dart";

import "../harness.dart";

void main() {
  late AppConfig config;
  late FileChatStore store;

  setUp(() {
    config = tempConfig();
    store = FileChatStore(config);
  });

  Message said(String id, String text) => Message(
    id: id,
    role: MessageRole.user,
    createdAt: DateTime.utc(2026, 1, 1),
    parts: [MessagePart.text(text: text)],
  );

  Future<void> chat(String id, {String text = "hello", String? project}) =>
      writeChatTo(
        store,
        Chat(
          state: makeState(id, project: project).copyWith(pinned: true),
          messages: [said("m1", text)],
        ),
      );

  void put(String path, List<int> bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  /// Bytes no zip makes smaller, so a size here is a size in the link.
  Uint8List noise(int length) {
    final random = Random(length);
    return Uint8List.fromList([
      for (var i = 0; i < length; i++) random.nextInt(256),
    ]);
  }

  SharePicks picks({
    Set<String> attachments = const {},
    Set<String> workspace = const {},
    Set<String> artifacts = const {},
  }) => {
    ShareSection.attachments: attachments,
    ShareSection.workspace: workspace,
    ShareSection.artifacts: artifacts,
  };

  ChatShareSource source({String? project}) =>
      ChatShareSource(config, "c1", project: project);

  Future<String?> pack(SharePicks picked, {String? project}) =>
      source(project: project).pack(picked);

  Uint8List zipOf(String? link) => shareZipOf(Uri.parse(link!).fragment)!;

  Future<AppConfig> unpacked(String? link) async {
    final dir = tempDir("share_unpacked_");
    final unpacked = await unpackShare(zipOf(link), dir.path);
    expect(unpacked?.chatId, "c1");
    return unpacked!.config;
  }

  group("packing and unpacking", () {
    test("carries the conversation and what was picked of each", () async {
      await chat("c1");
      put(p.join(config.resourcesDir("c1"), "photo.png"), [1, 2, 3]);
      put(p.join(config.resourcesDir("c1"), "big.jpeg"), [9]);
      put(p.join(config.workspaceDir("c1"), "src/main.dart"), utf8.encode("x"));
      put(p.join(config.workspaceDir("c1"), "notes.md"), utf8.encode("y"));
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [4]);
      put(p.join(config.artifactDir("c1", "a2"), "index.html"), [5]);

      final shared = await unpacked(
        await pack(
          picks(
            attachments: {"photo.png"},
            workspace: {"src/main.dart"},
            artifacts: {"a1"},
          ),
        ),
      );

      final loaded = await FileChatStore(shared).load("c1");
      expect(loaded.messages.single.parts.single, isA<TextPart>());
      expect(
        File(p.join(shared.resourcesDir("c1"), "photo.png")).readAsBytesSync(),
        [1, 2, 3],
      );
      expect(
        File(p.join(shared.resourcesDir("c1"), "big.jpeg")).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(shared.workspaceDir("c1"), "src/main.dart")).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(shared.workspaceDir("c1"), "notes.md")).existsSync(),
        isFalse,
      );
      expect(Directory(shared.artifactDir("c1", "a1")).existsSync(), isTrue);
      expect(Directory(shared.artifactDir("c1", "a2")).existsSync(), isFalse);
    });

    test("carries the chat bare and marked imported", () async {
      await chat("c1");

      final shared = await unpacked(await pack(picks()));
      final state = (await FileChatStore(shared).loadState("c1"))!;

      expect(state.title, "Test chat c1");
      expect(state.imported, isTrue);
      expect(state.pinned, isFalse);
      expect(File(shared.metaFile("c1")).existsSync(), isFalse);
    });

    test("reads a chat out of another project into the default one", () async {
      await chat("c1", project: "work");

      final shared = await unpacked(await pack(picks(), project: "work"));

      expect(File(shared.convFile("c1")).existsSync(), isTrue);
    });

    test("stamps the unpacked directory at the end of the chain", () async {
      await chat("c1");

      final shared = await unpacked(await pack(picks()));

      expect(
        File(migrationStamp(shared.dataDir)).readAsStringSync(),
        migrations.last.version,
      );
    });
  });

  group("measuring", () {
    test("the bare cost and each piece's add up to the zip exactly", () async {
      await chat("c1", text: "hello " * 500);
      put(p.join(config.resourcesDir("c1"), "photo.png"), noise(3000));
      put(p.join(config.workspaceDir("c1"), "src/main.dart"), utf8.encode("x"));
      put(
        p.join(config.workspaceDir("c1"), "notes.md"),
        utf8.encode("y" * 900),
      );
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [4, 5]);
      put(p.join(config.artifactDir("c1", "a1"), "style.css"), [6]);
      final picked = picks(
        attachments: {"photo.png"},
        workspace: {"src/main.dart", "notes.md"},
        artifacts: {"a1"},
      );
      final share = source();

      var bytes = await share.base();
      for (final MapEntry(key: section, value: ids) in picked.entries) {
        for (final id in ids) {
          bytes += (await share.measure([(section, id)]))[(section, id)]!;
        }
      }

      expect(bytes, zipOf(await share.pack(picked)).length);
    });

    test("is what the fit leaves out by", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "big.bin"), noise(200 * 1024));
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [1]);
      final picked = picks(workspace: {"big.bin"}, artifacts: {"a1"});
      final share = source();
      final costs = await share.measure([
        for (final MapEntry(key: section, value: ids) in picked.entries)
          for (final id in ids) (section, id),
      ]);

      final fit = shareFit(
        base: await share.base(),
        picks: picked,
        cost: (section, id) => costs[(section, id)]!,
      );
      final link = await share.pack(fit.kept(picked));

      expect(fit.dropped, {ShareSection.workspace});
      expect(link!.length, fit.length);
      final shared = await unpacked(link);
      expect(Directory(shared.artifactDir("c1", "a1")).existsSync(), isTrue);
      expect(
        File(p.join(shared.workspaceDir("c1"), "big.bin")).existsSync(),
        isFalse,
      );
    });

    test("a piece too big for any link is not compressed to say so", () async {
      await chat("c1");
      // Zeros deflate as far as anything does, and still cannot fit.
      put(p.join(config.workspaceDir("c1"), "zeros.bin"), Uint8List(64 << 20));
      final share = source();

      final costs = await share.measure([
        (ShareSection.workspace, "zeros.bin"),
      ]);
      final fit = shareFit(
        base: await share.base(),
        picks: picks(workspace: {"zeros.bin"}),
        cost: (section, id) => costs[(section, id)]!,
      );

      expect(fit.dropped, {ShareSection.workspace});
    });

    test("a pack past the cap is no link", () async {
      await chat("c1");
      put(p.join(config.resourcesDir("c1"), "big.jpeg"), noise(200 * 1024));

      expect(await pack(picks(attachments: {"big.jpeg"})), isNull);
    });
  });

  group("the candidates", () {
    test("are the workspace's files, a secret among them unticked", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "src/main.dart"), [1, 2]);
      put(p.join(config.workspaceDir("c1"), ".env"), [1]);
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [1, 2, 3]);

      final candidates = await source().candidates();

      expect(
        {
          for (final f in candidates[ShareSection.workspace]!)
            f.path: f.suggested,
        },
        {"src/main.dart": true, ".env": false},
      );
      expect(candidates[ShareSection.artifacts]!.single.path, "a1");
      expect(candidates[ShareSection.artifacts]!.single.size, 3);
    });

    test("list an ignored folder as one unticked line", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "app/node_modules/x/a.js"), [1]);
      put(p.join(config.workspaceDir("c1"), "app/main.js"), [1]);

      final workspace = (await source().candidates())[ShareSection.workspace]!;

      expect(
        {for (final f in workspace) f.path: (f.suggested, f.folder)},
        {"app/node_modules": (false, true), "app/main.js": (true, false)},
      );
    });

    test("a ticked folder carries everything under it", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), ".git/HEAD"), utf8.encode("ref"));

      final shared = await unpacked(await pack(picks(workspace: {".git"})));

      expect(
        File(p.join(shared.workspaceDir("c1"), ".git/HEAD")).readAsStringSync(),
        "ref",
      );
    });

    test("are the chat's attachments, each ticked", () async {
      await chat("c1");
      put(p.join(config.resourcesDir("c1"), "photo.png"), [1, 2]);

      final candidates = await source().candidates();

      expect(candidates[ShareSection.attachments]!.single.path, "photo.png");
      expect(candidates[ShareSection.attachments]!.single.size, 2);
      expect(candidates[ShareSection.attachments]!.single.suggested, isTrue);
    });
  });

  group("a zip that is not a shared chat", () {
    Uint8List zip(Map<String, List<int>> files) {
      final archive = Archive();
      files.forEach(
        (name, bytes) => archive.add(ArchiveFile.bytes(name, bytes)),
      );
      return ZipEncoder().encodeBytes(archive);
    }

    final conv = "projects/default/chats/c1/conv.jsonl";

    test("without a manifest is refused", () async {
      final dir = tempDir();
      expect(
        await unpackShare(
          zip({
            "version": [1],
            conv: [],
          }),
          dir.path,
        ),
        isNull,
      );
    });

    test("naming a chat outside its folder is refused", () async {
      final dir = tempDir();
      final shared = zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode(jsonEncode({"chat": "../c1"})),
        conv: [],
      });

      expect(await unpackShare(shared, dir.path), isNull);
    });

    final state = "projects/default/chats/c1/state.json";
    final stateBytes = utf8.encode(
      jsonEncode(
        ChatState(
          id: "c1",
          title: "t",
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ).toJson(),
      ),
    );

    test("writes nothing outside the chat's own folders", () async {
      final dir = tempDir();
      final shared = zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode(jsonEncode({"chat": "c1"})),
        conv: [],
        state: stateBytes,
        "settings.json": utf8.encode("{}"),
        "projects/default/chats/c2/conv.jsonl": [],
      });

      expect((await unpackShare(shared, dir.path))?.chatId, "c1");
      expect(File(p.join(dir.path, "settings.json")).existsSync(), isFalse);
      expect(
        Directory(p.join(dir.path, "projects/default/chats/c2")).existsSync(),
        isFalse,
      );
    });

    test("leaves out a chat's settings, which a share never carries", () async {
      final dir = tempDir();
      final shared = zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode(jsonEncode({"chat": "c1"})),
        conv: [],
        state: stateBytes,
        "projects/default/chats/c1/meta.json": utf8.encode(
          jsonEncode({"sandbox": false}),
        ),
      });

      final unpacked = await unpackShare(shared, dir.path);

      expect(unpacked?.chatId, "c1");
      expect(File(unpacked!.config.metaFile("c1")).existsSync(), isFalse);
    });

    test("without a state, or one that is not JSON, is refused", () async {
      Uint8List withState(List<int>? bytes) => zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode(jsonEncode({"chat": "c1"})),
        conv: [],
        if (bytes != null) state: bytes,
      });

      expect(await unpackShare(withState(null), tempDir().path), isNull);
      expect(
        await unpackShare(withState(utf8.encode("{")), tempDir().path),
        isNull,
      );
    });

    test("with a manifest that is not JSON is refused", () async {
      final shared = zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode("not json"),
        conv: [],
        state: stateBytes,
      });

      expect(await unpackShare(shared, tempDir().path), isNull);
    });
  });

  group("importing", () {
    test(
      "is a new chat in the project, imported, its workspace with it",
      () async {
        await chat("c1");
        put(p.join(config.workspaceDir("c1"), "notes.md"), utf8.encode("y"));
        final link = await pack(picks(workspace: {"notes.md"}));
        final into = tempConfig();

        final id = await importShare(
          zipOf(link),
          FileChatStore(into),
          project: "work",
        );

        expect(id, isNot("c1"));
        final imported = await FileChatStore(into).load(id!);
        expect(imported.state.id, id);
        expect(imported.state.project, "work");
        expect(imported.state.imported, isTrue);
        expect(imported.messages.single.id, "m1");
        expect(
          File(
            p.join(into.workspaceDir(id, project: "work"), "notes.md"),
          ).readAsStringSync(),
          "y",
        );
      },
    );

    test("twice is two chats", () async {
      await chat("c1");
      final zip = zipOf(await pack(picks()));

      final first = await importShare(zip, store);
      final second = await importShare(zip, store);

      expect({first, second, "c1"}, hasLength(3));
    });
  });
}
