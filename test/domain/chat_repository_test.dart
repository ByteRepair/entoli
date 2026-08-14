import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_repository.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late FakeBackend backend;

  ChatRepository repoWith(AppSettings settings) {
    final config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);
    return ChatRepository(LocalChatStore(config), backend, settings);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_repo_test_");
    backend = FakeBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test("a chat without its own model runs on the app default", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await repo.createChat();

    await repo.sendPrompt(chat.state.id, "hi").toList();

    expect(backend.prompts.single.provider, "anthropic");
    expect(backend.prompts.single.model, "claude-sonnet-4");
  });

  test("a chat's own model wins over the app default", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await repo.createChat();

    await repo
        .sendPrompt(chat.state.id, "hi", model: "qwen-2.5", provider: "ollama-cloud")
        .toList();

    expect(backend.prompts.single.provider, "ollama-cloud");
    expect(backend.prompts.single.model, "qwen-2.5");
  });

  test("a chat's model is never paired with the app default's provider", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await repo.createChat();

    await repo.sendPrompt(chat.state.id, "hi", model: "qwen-2.5").toList();

    expect(backend.prompts.single.model, "qwen-2.5");
    expect(backend.prompts.single.provider, isNull);
  });
}
