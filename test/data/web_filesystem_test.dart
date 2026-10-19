import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_memory.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/tristate.dart";
import "package:agent_chat/domain/workspace.dart";

import "../harness.dart";

/// The browser's filesystem, on the VM. `newFileSystemMemory` is the same
/// `FileSystemIdb` the web build runs on, over an in-memory IndexedDB instead
/// of the browser's — so everything here is the web path, and it is otherwise
/// reachable only by loading the app in a tab.
///
/// Reusing one filesystem across two `AppConfig`s is a reload: the second is
/// the app starting again over storage that outlived it.
void main() {
  late FileSystem fs;
  late AppConfig config;
  late FileChatStore store;

  setUp(() async {
    fs = newFileSystemMemory();
    config = await AppConfig.load(fs, "/entoli");
    store = FileChatStore(config);
  });

  Chat chatOf(String id, {String? project}) => Chat(
        state: makeState(id, project: project),
        messages: [
          Message(
            id: "m1",
            role: MessageRole.user,
            createdAt: DateTime.utc(2026, 1, 1),
            parts: [const MessagePart.text(text: "hello")],
          ),
        ],
      );

  group("chats", () {
    test("save round-trips a chat", () async {
      await writeChatTo(store, chatOf("c1"));

      final chat = await store.load("c1");
      expect(chat.state.title, "Test chat c1");
      expect(chat.messages.single.parts.single, const MessagePart.text(text: "hello"));
    });

    test("load throws for a chat nothing was saved under", () {
      expect(store.load("nope"), throwsStateError);
    });

    test("list is newest first and stamps each chat with its project", () async {
      await store.createProject("work");
      await store.saveState(makeState("old", day: 1));
      await store.saveState(makeState("new", day: 3));
      await writeChatTo(store, chatOf("scoped", project: "work"));

      final listed = await store.list();
      expect(listed.map((s) => s.id), ["new", "scoped", "old"]);
      expect(listed.firstWhere((s) => s.id == "scoped").project, "work");
      expect(await store.projectOf("scoped"), "work");
      expect(await store.projectOf("old"), isNull);
    });

    test("saveState keeps the messages already written", () async {
      await writeChatTo(store, chatOf("c1"));
      await store.saveState(makeState("c1").copyWith(title: "Renamed"));

      final chat = await store.load("c1");
      expect(chat.state.title, "Renamed");
      expect(chat.messages, hasLength(1));
    });

    test("where a chat already is wins over what a held copy says", () async {
      await store.createProject("work");
      await writeChatTo(store, chatOf("c1", project: "work"));
      // A copy from before the chat was in a project, saved late.
      await store.saveState(makeState("c1"));

      expect(await store.projectOf("c1"), "work");
    });

    test("moveChat moves a chat between projects", () async {
      await store.createProject("work");
      await writeChatTo(store, chatOf("c1"));
      await store.moveChat("c1", "work");
      expect((await store.load("c1")).state.project, "work");

      await store.moveChat("c1", null);
      expect((await store.load("c1")).state.project, isNull);
    });

    test("deleteProject takes its chats with it", () async {
      await store.createProject("work");
      await writeChatTo(store, chatOf("kept"));
      await writeChatTo(store, chatOf("gone", project: "work"));

      await store.deleteProject("work");

      expect(await store.listProjects(), isEmpty);
      expect((await store.list()).map((s) => s.id), ["kept"]);
    });

    test("meta is written and read back per chat", () async {
      await store.saveMeta("c1", ChatMeta(model: "qwen-2.5", provider: "ollama"));

      final loaded = await store.loadMeta("c1");
      expect(loaded.model, "qwen-2.5");
      expect(loaded.approveMode, isNull);
      expect((await store.loadMeta("c2")).model, isNull);
    });
  });

  group("attachments", () {
    test("bytes are stored as bytes, per chat, and go with a delete", () async {
      final bytes = Uint8List.fromList([0, 1, 2, 253, 254, 255]);
      await writeChatTo(store, chatOf("c1"));
      final resource = await store.saveResource("c1", "shot.png", bytes);

      expect(resource, endsWith("-shot.png"));
      expect(await store.readResource("c1", resource), bytes);
      expect(await store.readResource("c2", resource), isNull);

      await store.delete("c1");
      expect(await store.readResource("c1", resource), isNull);
    });
  });

  // The viewer reads a prefix rather than the file, and a prefix out of
  // IndexedDB is a different code path from one off a disk.
  group("reading a workspace file", () {
    late String path;

    setUp(() async {
      await fs.directory(config.projectWorkspaceDir()).create(recursive: true);
      path = "${config.projectWorkspaceDir()}/notes.md";
    });

    test("a small one comes back whole", () async {
      await fs.file(path).writeAsString("hello");

      final content = await readTextHead(fs, path);

      expect(content!.text, "hello");
      expect(content.truncated, isFalse);
    });

    test("a big one stops at the cap", () async {
      await fs.file(path).writeAsString("x" * (textViewLimit + 500));

      final content = await readTextHead(fs, path);

      expect(content!.text.length, textViewLimit);
      expect(content.truncated, isTrue);
    });
  });

  group("settings", () {
    test("a filesystem with nothing written to it is the defaults", () {
      expect(AppSettings.load(config).llmProviders, isEmpty);
      expect(AppSettings.load(config).approveMode, ApproveMode.auto);
      expect(ProjectSettings.load(config).memory, Tristate.inherit);
    });

    test("what was saved reads back without waiting for the write", () async {
      final saving = AppSettings(defaultProviderId: "ollama", defaultModelId: "qwen-2.5")
          .save(config);

      // The copy is updated before the filesystem is, so a read on the next
      // line sees it — which is what lets `AppSettings.load` stay synchronous.
      expect(AppSettings.load(config).defaultProviderId, "ollama");
      await saving;
    });

    test("a project's settings are their own, and keyed by project", () async {
      await store.createProject("work");
      await ProjectSettings(memory: Tristate.on).save(config, project: "work");

      expect(ProjectSettings.load(config, project: "work").memory, Tristate.on);
      expect(ProjectSettings.load(config).memory, Tristate.inherit);
    });
  });

  group("across a reload", () {
    test("chats, their messages and their attachments are still there", () async {
      await store.createProject("work");
      await writeChatTo(store, chatOf("kept", project: "work"));
      await store.saveMeta("kept", ChatMeta(model: "qwen-2.5"));
      final resource = await store.saveResource("kept", "note.txt", Uint8List.fromList([7]));

      final reloaded = FileChatStore(await AppConfig.load(fs, "/entoli"));

      expect((await reloaded.list()).single.id, "kept");
      expect((await reloaded.load("kept")).messages, hasLength(1));
      expect(await reloaded.projectOf("kept"), "work");
      expect((await reloaded.loadMeta("kept")).model, "qwen-2.5");
      expect(await reloaded.readResource("kept", resource), [7]);
      expect(await reloaded.listProjects(), ["work"]);
    });

    test("settings are still there, app-level and per project", () async {
      await AppSettings(
        defaultProviderId: "ollama",
        approveMode: ApproveMode.never,
        llmProviders: const [
          LlmProviderConfig(id: "ollama", api: LlmApi.openai, baseUrl: "http://localhost:11434/v1"),
        ],
      ).save(config);
      await store.createProject("work");
      await ProjectSettings(memory: Tristate.on).save(config, project: "work");

      final reloaded = await AppConfig.load(fs, "/entoli");

      expect(AppSettings.load(reloaded).defaultProviderId, "ollama");
      expect(AppSettings.load(reloaded).approveMode, ApproveMode.never);
      expect(AppSettings.load(reloaded).llmProviders.single.id, "ollama");
      expect(ProjectSettings.load(reloaded, project: "work").memory, Tristate.on);
    });
  });
}
