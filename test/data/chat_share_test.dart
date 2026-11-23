import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/migrations.dart";
import "package:agent_chat/data/chat_share.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/chat_share.dart";
import "package:agent_chat/domain/models.dart";

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

  Uint8List zipOf(SharePack pack) =>
      shareZipOf(Uri.parse(pack.link!).fragment)!;

  Future<AppConfig> unpacked(SharePack pack) async {
    final dir = tempDir("share_unpacked_");
    expect(await unpackShare(zipOf(pack), dir.path), "c1");
    return AppConfig.forDirectory(dir.path);
  }

  group("packing and unpacking", () {
    test(
      "carries the conversation, what was attached and what was picked",
      () async {
        await chat("c1");
        put(p.join(config.resourcesDir("c1"), "photo.png"), [1, 2, 3]);
        put(
          p.join(config.workspaceDir("c1"), "src/main.dart"),
          utf8.encode("x"),
        );
        put(p.join(config.workspaceDir("c1"), "notes.md"), utf8.encode("y"));
        put(p.join(config.artifactDir("c1", "a1"), "index.html"), [4]);
        put(p.join(config.artifactDir("c1", "a2"), "index.html"), [5]);

        final pack = await packShare(
          config,
          "c1",
          workspace: {"src/main.dart"},
          artifacts: {"a1"},
        );
        final shared = await unpacked(pack);

        expect(pack.droppedWorkspace, isFalse);
        expect(pack.droppedArtifacts, isFalse);
        final loaded = await FileChatStore(shared).load("c1");
        expect(loaded.messages.single.parts.single, isA<TextPart>());
        expect(
          File(
            p.join(shared.resourcesDir("c1"), "photo.png"),
          ).readAsBytesSync(),
          [1, 2, 3],
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
      },
    );

    test("carries the chat bare and marked imported", () async {
      await chat("c1");

      final shared = await unpacked(await packShare(config, "c1"));
      final state = (await FileChatStore(shared).loadState("c1"))!;

      expect(state.title, "Test chat c1");
      expect(state.imported, isTrue);
      expect(state.pinned, isFalse);
      expect(File(shared.metaFile("c1")).existsSync(), isFalse);
    });

    test("reads a chat out of another project into the default one", () async {
      await chat("c1", project: "work");

      final shared = await unpacked(
        await packShare(config, "c1", project: "work"),
      );

      expect(File(shared.convFile("c1")).existsSync(), isTrue);
    });

    test("stamps the unpacked directory at the end of the chain", () async {
      await chat("c1");

      final shared = await unpacked(await packShare(config, "c1"));

      expect(
        File(migrationStamp(shared.dataDir)).readAsStringSync(),
        migrations.last.version,
      );
    });
  });

  group("a long link", () {
    test("leaves the workspace out first", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "big.bin"), noise(200 * 1024));
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [1]);

      final pack = await packShare(
        config,
        "c1",
        workspace: {"big.bin"},
        artifacts: {"a1"},
      );
      final shared = await unpacked(pack);

      expect(pack.link!.length, lessThanOrEqualTo(shareLinkMaxLength));
      expect(pack.droppedWorkspace, isTrue);
      expect(pack.droppedArtifacts, isFalse);
      expect(Directory(shared.artifactDir("c1", "a1")).existsSync(), isTrue);
    });

    test("then the artifacts", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "a.txt"), [1]);
      put(p.join(config.artifactDir("c1", "a1"), "big.bin"), noise(200 * 1024));

      final pack = await packShare(
        config,
        "c1",
        workspace: {"a.txt"},
        artifacts: {"a1"},
      );

      expect(pack.droppedWorkspace, isTrue);
      expect(pack.droppedArtifacts, isTrue);
      expect(pack.link, isNotNull);
    });

    test("whose conversation alone is too long is no link", () async {
      await chat("c1", text: base64.encode(noise(200 * 1024)));

      final pack = await packShare(config, "c1");

      expect(pack.link, isNull);
      expect(pack.length, greaterThan(shareLinkMaxLength));
    });
  });

  group("the candidates", () {
    test("are the workspace's files, a secret among them unticked", () async {
      await chat("c1");
      put(p.join(config.workspaceDir("c1"), "src/main.dart"), [1, 2]);
      put(p.join(config.workspaceDir("c1"), ".env"), [1]);
      put(p.join(config.artifactDir("c1", "a1"), "index.html"), [1, 2, 3]);

      final candidates = await shareCandidates(config, "c1");

      expect(
        {for (final f in candidates.workspace) f.path: f.suggested},
        {"src/main.dart": true, ".env": false},
      );
      expect(candidates.artifacts.single.path, "a1");
      expect(candidates.artifacts.single.size, 3);
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

    test("writes nothing outside the chat's own folders", () async {
      final dir = tempDir();
      final shared = zip({
        "version": utf8.encode(migrations.last.version),
        "share.json": utf8.encode(jsonEncode({"chat": "c1"})),
        conv: [],
        "settings.json": utf8.encode("{}"),
        "projects/default/chats/c2/conv.jsonl": [],
      });

      expect(await unpackShare(shared, dir.path), "c1");
      expect(File(p.join(dir.path, "settings.json")).existsSync(), isFalse);
      expect(
        Directory(p.join(dir.path, "projects/default/chats/c2")).existsSync(),
        isFalse,
      );
    });
  });

  group("importing", () {
    test(
      "is a new chat in the project, imported, its workspace with it",
      () async {
        await chat("c1");
        put(p.join(config.workspaceDir("c1"), "notes.md"), utf8.encode("y"));
        final pack = await packShare(config, "c1", workspace: {"notes.md"});
        final into = tempConfig();

        final id = await importShare(zipOf(pack), into, project: "work");

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
      final zip = zipOf(await packShare(config, "c1"));

      final first = await importShare(zip, config);
      final second = await importShare(zip, config);

      expect({first, second, "c1"}, hasLength(3));
    });
  });
}
