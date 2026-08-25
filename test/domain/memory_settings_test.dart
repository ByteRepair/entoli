import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/project_settings.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late AppConfig config;
  late FakeBackend backend;

  ChatRepository repoWith(AppSettings settings) =>
      ChatRepository(FileChatStore(config), backend, () => settings, config);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("memory_settings_test_");
    config = AppConfig.forDirectory(tmp.path, fileSystemIo);
    Directory(config.chatsDir()).createSync(recursive: true);
    backend = FakeBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A project whose directory exists, which saving its settings and running
  /// its chats both need.
  void makeProject(String name) =>
      Directory(config.projectDir(project: name)).createSync(recursive: true);

  group("settings round-trip", () {
    test("the app-level memory fields survive save and load", () async {
      final settings = AppSettings(
        loadInstructions: true,
        instructionImports: true,
        nestedInstructions: true,
        autoMemory: true,
        memoryRecall: false,
        memoryExtraction: false,
        memoryAgentTool: false,
        memoryProviderId: "ollama-cloud",
        memoryModelId: "qwen-2.5",
      );
      await settings.save(config);

      final loaded = AppSettings.load(config);
      expect(loaded.loadInstructions, isTrue);
      expect(loaded.instructionImports, isTrue);
      expect(loaded.nestedInstructions, isTrue);
      expect(loaded.autoMemory, isTrue);
      expect(loaded.memoryRecall, isFalse);
      expect(loaded.memoryExtraction, isFalse);
      expect(loaded.memoryAgentTool, isFalse);
      expect(loaded.memoryProviderId, "ollama-cloud");
      expect(loaded.memoryModelId, "qwen-2.5");
    });

    // The sub-gates default on: a file that turns auto-memory on without
    // naming them says nothing, and gets recall, extraction and the tools.
    test("the memory sub-gates default on", () async {
      await AppSettings(autoMemory: true).save(config);
      final loaded = AppSettings.load(config);
      expect(loaded.memoryRecall, isTrue);
      expect(loaded.memoryExtraction, isTrue);
      expect(loaded.memoryAgentTool, isTrue);
    });

    // Defaults write nothing: an untouched settings.json carries no memory
    // keys, so a file from before the feature stays exactly as it was.
    test("defaults leave no trace", () async {
      await AppSettings().save(config);
      final json =
          jsonDecode(File(config.settingsFile).readAsStringSync())
              as Map<String, dynamic>;
      for (final key in [
        "loadInstructions",
        "instructionImports",
        "nestedInstructions",
        "autoMemory",
        "memoryRecall",
        "memoryExtraction",
        "memoryAgentTool",
        "memoryModelId",
        "memoryProviderId",
      ]) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
    });

    test("a project's own-memory toggle survives save and load", () async {
      makeProject("proj");
      makeProject("proj");
      await ProjectSettings(useProjectMemory: true).save(config, project: "proj");

      expect(ProjectSettings.load(config, project: "proj").useProjectMemory,
          isTrue);
      expect(ProjectSettings.load(config).useProjectMemory, isFalse);
    });
  });

  group("turn-time resolution", () {
    test("everything off resolves to nothing at all", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory, MemorySettings.off);
    });

    test("the instructions gates travel alone", () async {
      final repo = repoWith(AppSettings(
        loadInstructions: true,
        nestedInstructions: true,
      ));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.instructions, isTrue);
      expect(memory.imports, isFalse);
      expect(memory.nested, isTrue);
      expect(memory.autoMemory, isFalse);
      expect(memory.memoryDir, isNull);
    });

    test("a default-project chat uses the default store", () async {
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.autoMemory, isTrue);
      expect(memory.memoryDir, config.memoryDir());
    });

    test("a project without its own toggle shares the default store", () async {
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory.memoryDir,
          config.memoryDir());
    });

    test("a project with its own toggle keeps its own store", () async {
      makeProject("proj");
      await ProjectSettings(useProjectMemory: true).save(config, project: "proj");
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory.memoryDir,
          config.memoryDir(project: "proj"));
    });

    test("auto-memory off means no store even where the toggle is on", () async {
      makeProject("proj");
      await ProjectSettings(useProjectMemory: true).save(config, project: "proj");
      final repo = repoWith(AppSettings(loadInstructions: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.instructions, isTrue);
      expect(memory.memoryDir, isNull);
    });

    test("the memory sub-gates travel with the turn", () async {
      final repo = repoWith(AppSettings(
        autoMemory: true,
        memoryRecall: false,
        memoryExtraction: false,
      ));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.recall, isFalse);
      expect(memory.extract, isFalse);
      expect(memory.agentTool, isTrue);
    });

    test("the memory sub-gates default on with the store", () async {
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.recall, isTrue);
      expect(memory.extract, isTrue);
      expect(memory.agentTool, isTrue);
    });

    test("the background model pair travels with the turn", () async {
      final repo = repoWith(AppSettings(
        autoMemory: true,
        memoryProviderId: "ollama-cloud",
        memoryModelId: "qwen-2.5",
      ));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.bgProvider, "ollama-cloud");
      expect(memory.bgModel, "qwen-2.5");
    });
  });
}
