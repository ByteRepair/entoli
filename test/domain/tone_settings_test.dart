import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/tone.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late AppConfig config;
  late FakeBackend backend;

  ChatRepository repoWith(AppSettings settings) =>
      ChatRepository(FileChatStore(config), backend, () => settings, config);

  setUp(() {
    config = tempConfig("tone_settings_test_");
    backend = FakeBackend();
  });

  /// A project whose directory exists, which saving its settings and running
  /// its chats both need.
  void makeProject(String name) =>
      Directory(config.projectDir(project: name)).createSync(recursive: true);

  group("settings round-trip", () {
    test("the app-level tone and citations survive save and load", () async {
      final settings = AppSettings(tone: Tone.direct, citations: true);
      await settings.save(config);

      final loaded = AppSettings.load(config);
      expect(loaded.tone, Tone.direct);
      expect(loaded.citations, isTrue);
    });

    test("an unknown tone name loads as none", () async {
      await AppSettings(tone: Tone.direct).save(config);
      // Documents is the copy the loads read: a file written behind it is not
      // seen until hydrate runs again (test/CLAUDE.md, "What the wire is not
      // tested against" is not this; the rule is "settings go through
      // config.documents").
      final path = config.settingsFile;
      final json =
          jsonDecode(config.documents.read(path)!) as Map<String, dynamic>;
      json["tone"] = "shouty";
      await config.documents.write(path, jsonEncode(json));

      expect(AppSettings.load(config).tone, Tone.none);
    });

    test("defaults leave no trace", () async {
      await AppSettings().save(config);
      final json =
          jsonDecode(File(config.settingsFile).readAsStringSync())
              as Map<String, dynamic>;
      expect(json.containsKey("tone"), isFalse);
      expect(json.containsKey("citations"), isFalse);
    });

    test("the project-level answers survive save and load", () async {
      makeProject("proj");
      await ProjectSettings(tone: Tone.kind, citations: false)
          .save(config, project: "proj");

      final loaded = ProjectSettings.load(config, project: "proj");
      expect(loaded.tone, Tone.kind);
      // Off is a written answer, not the absent one: the project said no.
      expect(loaded.citations, isFalse);
    });

    test("a project's absent keys load as null", () async {
      makeProject("proj");
      await ProjectSettings().save(config, project: "proj");

      final loaded = ProjectSettings.load(config, project: "proj");
      expect(loaded.tone, isNull);
      expect(loaded.citations, isNull);
    });
  });

  group("turn-time resolution", () {
    test("the app's answers travel with the turn", () async {
      final repo = repoWith(AppSettings(tone: Tone.formal, citations: true));
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.tone, Tone.formal);
      expect(settings.citations, isTrue);
    });

    test("the defaults travel as none and off", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.tone, Tone.none);
      expect(settings.citations, isFalse);
    });

    test("the project's answer stands over the app's", () async {
      makeProject("proj");
      await ProjectSettings(tone: Tone.kind).save(config, project: "proj");
      final repo = repoWith(AppSettings(tone: Tone.direct, citations: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.tone, Tone.kind);
      // The project only answered the tone; the app's citations stands.
      expect(settings.citations, isTrue);
    });

    test("a project's explicit off stands over the app's on", () async {
      makeProject("proj");
      await ProjectSettings(citations: false).save(config, project: "proj");
      final repo = repoWith(AppSettings(citations: true));
      final chat = await repo.createChat(project: "proj");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.citations, isFalse);
    });
  });
}