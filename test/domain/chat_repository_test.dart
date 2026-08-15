import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late FakeBackend backend;

  late AppConfig config;

  ChatRepository repoWith(AppSettings settings) =>
      ChatRepository(LocalChatStore(config), backend, () => settings);

  /// What the chat settings page would have written.
  void pinChatModel(String chatId, {String? provider, String? model}) =>
      ChatMeta(provider: provider, model: model).saveTo(config.metaFile(chatId));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_repo_test_");
    config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);
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

    pinChatModel(chat.state.id, provider: "ollama-cloud", model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, "hi").toList();

    expect(backend.prompts.single.provider, "ollama-cloud");
    expect(backend.prompts.single.model, "qwen-2.5");
  });

  test("a chat's model is never paired with the app default's provider", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await repo.createChat();

    pinChatModel(chat.state.id, model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, "hi").toList();

    expect(backend.prompts.single.model, "qwen-2.5");
    expect(backend.prompts.single.provider, isNull);
  });

  test("an attachment saved as a part reads back with its bytes", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();

    final parts = await repo.saveAttachments(chat.state.id, [testAttachment("notes.txt")]);
    final message = Message(
      id: "m1",
      role: MessageRole.user,
      createdAt: DateTime(2026),
      parts: parts,
    );

    final loaded = await repo.loadAttachments(chat.state.id, message);
    expect(loaded.single.filename, "notes.txt");
    expect(loaded.single.mimeType, "text/plain");
    expect(loaded.single.bytes, [104, 105]);
  });

  // Regenerating a message repeatedly would otherwise copy its bytes each time.
  test("an attachment already on disk is not saved a second time", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();

    final first = await repo.saveAttachments(chat.state.id, [testAttachment("notes.txt")]);
    final message = Message(
      id: "m1",
      role: MessageRole.user,
      createdAt: DateTime(2026),
      parts: first,
    );
    final again = await repo.saveAttachments(
      chat.state.id,
      await repo.loadAttachments(chat.state.id, message),
    );

    expect((again.single as FilePart).resource, (first.single as FilePart).resource);
    expect(config.resourcesDir(chat.state.id).listSync(), hasLength(1));
  });

  test("an attachment whose file has gone is dropped, not resent empty", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();

    final message = Message(
      id: "m1",
      role: MessageRole.user,
      createdAt: DateTime(2026),
      parts: const [
        MessagePart.file(resource: "gone.txt", filename: "notes.txt", mimeType: "text/plain"),
      ],
    );

    expect(await repo.loadAttachments(chat.state.id, message), isEmpty);
  });
}
