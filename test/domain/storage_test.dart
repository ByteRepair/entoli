import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/memory_storage.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/profile.dart";
import "package:agent_chat/domain/project_settings.dart";

/// The platform with no filesystem, which until there was a port could only be
/// exercised by loading the app in a browser.
void main() {
  group("MemoryStorage", () {
    test("reads back what was written, and null for a path never written", () {
      final storage = MemoryStorage();
      storage.write("/agent-chat/settings.json", '{"appIcon":"cookie"}');

      expect(storage.read("/agent-chat/settings.json"), '{"appIcon":"cookie"}');
      expect(storage.read("/agent-chat/project.json"), isNull);
    });

    test("making a directory is nothing, and leaves none behind", () async {
      final storage = MemoryStorage();
      final config = await AppConfig.load(storage);
      config.ensureChatDirs("c1");

      expect(Directory(config.chatDir("c1").path).existsSync(), isFalse);
      expect(Directory(config.dataDir.path).existsSync(), isFalse);
    });
  });

  group("settings over a storage with no filesystem", () {
    late AppConfig config;

    setUp(() async => config = await AppConfig.load(MemoryStorage()));

    test("a config with nothing written to it is the defaults", () {
      final settings = AppSettings.load(config);
      expect(settings.llmProviders, isEmpty);
      expect(settings.approveMode, ApproveMode.ask);
      expect(ProjectSettings.load(config).profile, isNull);
    });

    test("what was saved is what loads, for the life of the object", () async {
      await AppSettings(
        defaultProviderId: "ollama",
        defaultModelId: "qwen-2.5",
        approveMode: ApproveMode.never,
        llmProviders: const [
          LlmProviderConfig(id: "ollama", api: LlmApi.openai, baseUrl: "http://localhost:11434/v1"),
        ],
      ).save(config);

      final loaded = AppSettings.load(config);
      expect(loaded.defaultProviderId, "ollama");
      expect(loaded.defaultModelId, "qwen-2.5");
      expect(loaded.approveMode, ApproveMode.never);
      expect(loaded.llmProviders.single.id, "ollama");
    });

    test("a project's settings are their own, and keyed by project", () async {
      await ProjectSettings(profile: const Profile(name: "Yiannis")).save(config, project: "work");

      expect(ProjectSettings.load(config, project: "work").profile?.name, "Yiannis");
      expect(ProjectSettings.load(config).profile, isNull);
    });

    test("a fresh storage remembers nothing, the way a reloaded tab does", () async {
      await AppSettings(defaultProviderId: "ollama").save(config);

      final reloaded = await AppConfig.load(MemoryStorage());
      expect(AppSettings.load(reloaded).defaultProviderId, isNull);
    });
  });
}
