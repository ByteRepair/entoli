import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/tristate.dart";

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
        instructionImports: false,
        nestedInstructions: false,
        autoMemory: true,
        memoryRecall: false,
        memoryExtraction: false,
        memoryAgentTool: false,
        memoryProviderId: "ollama-cloud",
        memoryModelId: "qwen-2.5",
      );
      await settings.save(config);

      final loaded = AppSettings.load(config);
      expect(loaded.instructionImports, isFalse);
      expect(loaded.nestedInstructions, isFalse);
      expect(loaded.autoMemory, isTrue);
      expect(loaded.memoryRecall, isFalse);
      expect(loaded.memoryExtraction, isFalse);
      expect(loaded.memoryAgentTool, isFalse);
      expect(loaded.memoryProviderId, "ollama-cloud");
      expect(loaded.memoryModelId, "qwen-2.5");

      // Omission means on: a file that turns auto-memory on without naming
      // the sub-gates gets recall, extraction and the tools. The instruction
      // half defaults on too, the files being read into every turn whether or
      // not the file names them.
      await AppSettings(autoMemory: true).save(config);
      final defaults = AppSettings.load(config);
      expect(defaults.instructionImports, isTrue);
      expect(defaults.nestedInstructions, isTrue);
      expect(defaults.memoryRecall, isTrue);
      expect(defaults.memoryExtraction, isTrue);
      expect(defaults.memoryAgentTool, isTrue);
    });

    // Defaults write nothing: an untouched settings.json carries no memory
    // keys, so a file from before the feature stays exactly as it was.
    test("defaults leave no trace", () async {
      await AppSettings().save(config);
      final json =
          jsonDecode(File(config.settingsFile).readAsStringSync())
              as Map<String, dynamic>;
      for (final key in [
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
      await ProjectSettings(memory: Tristate.on).save(config, project: "proj");

      expect(ProjectSettings.load(config, project: "proj").memory, Tristate.on);
      expect(ProjectSettings.load(config).memory, Tristate.inherit);
    });

    test("the bool it replaced still loads", () {
      expect(ProjectSettings.fromJson({"useProjectMemory": true}).memory,
          Tristate.on);
      expect(ProjectSettings.fromJson({}).memory, Tristate.inherit);
    });
  });

  group("turn-time resolution", () {
    test("nothing on resolves to a turn with no store", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.autoMemory, isFalse);
      expect(memory.memoryDir, isNull);
      expect(memory.bgModel, isNull);
      // The AGENTS.md half does not ride on the store: its answers travel
      // with the turn whatever the store says.
      expect(memory.imports, isTrue);
      expect(memory.nested, isTrue);
    });

    test("the instruction answers travel with the turn", () async {
      final repo = repoWith(AppSettings(
        instructionImports: false,
        nestedInstructions: false,
      ));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.imports, isFalse);
      expect(memory.nested, isFalse);
      expect(memory.autoMemory, isFalse);
      expect(memory.memoryDir, isNull);
    });

    test("the default store answers the default project and a toggle-less one", () async {
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.autoMemory, isTrue);
      expect(memory.memoryDir, config.memoryDir());

      // A project without its own toggle shares the default store.
      final other = await repo.createChat(project: "proj");
      await repo.sendPrompt(other.state.id, userMessage("hi")).toList();
      expect(backend.prompts.last.settings.memory.memoryDir,
          config.memoryDir());
    });

    test("a project with its own toggle keeps its own store", () async {
      makeProject("proj");
      await ProjectSettings(memory: Tristate.on).save(config, project: "proj");
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory.memoryDir,
          config.memoryDir(project: "proj"));
    });

    test("a project set to off has no memory", () async {
      makeProject("proj");
      await ProjectSettings(memory: Tristate.off).save(config, project: "proj");
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory, MemorySettings.off);
    });

    test("auto-memory off means no store even where the toggle is on", () async {
      makeProject("proj");
      await ProjectSettings(memory: Tristate.on).save(config, project: "proj");
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final memory = backend.prompts.single.settings.memory;
      expect(memory.autoMemory, isFalse);
      expect(memory.memoryDir, isNull);
    });

    test("the sub-gates travel with the turn, on by default where the file says nothing", () async {
      // The named-off ones ride off; the unnamed one rides on with the store.
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

      // Nothing named: all three ride on with the store.
      final defaults = repoWith(AppSettings(autoMemory: true));
      final other = await defaults.createChat();
      await defaults.sendPrompt(other.state.id, userMessage("hi")).toList();
      final on = backend.prompts.last.settings.memory;
      expect(on.recall, isTrue);
      expect(on.extract, isTrue);
      expect(on.agentTool, isTrue);
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

    test("one chat's keep-out does not reach the rest of the project",
        () async {
      final repo = repoWith(AppSettings(autoMemory: true));
      final off = await repo.createChat(meta: ChatMeta(memoryOff: true));
      final on = await repo.createChat();

      await repo.sendPrompt(off.state.id, userMessage("hi")).toList();
      await repo.sendPrompt(on.state.id, userMessage("hi")).toList();

      expect(backend.prompts.first.settings.memory, MemorySettings.off);
      expect(backend.prompts.last.settings.memory.memoryDir,
          config.memoryDir());
    });

    // The chat's off cannot be argued out of by a project that has a store.
    test("the keep-out stands over a project's own store", () async {
      makeProject("proj");
      await ProjectSettings(memory: Tristate.on).save(config, project: "proj");
      final repo = repoWith(AppSettings(autoMemory: true));
      final chat = await repo.createChat(
          project: "proj", meta: ChatMeta(memoryOff: true));

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.memory, MemorySettings.off);
    });
  });
}
