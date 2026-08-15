import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/disk_storage.dart";
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
      ChatRepository(LocalChatStore(config), backend, () => settings, config);

  /// A chat that is on disk, the way one is by the time a prompt is sent.
  Future<Chat> savedChat(ChatRepository repo) async {
    final chat = await repo.createChat();
    await repo.save(chat);
    return chat;
  }

  /// What the chat settings page would have written.
  void pinChatModel(String chatId, {String? provider, String? model}) {
    config.ensureChatDirs(chatId);
    ChatMeta(provider: provider, model: model).saveTo(config.metaFile(chatId));
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_repo_test_");
    config = AppConfig.forDirectory(tmp, const DiskStorage());
    config.ensureProjectDirs();
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
    final chat = await savedChat(repo);

    pinChatModel(chat.state.id, provider: "ollama-cloud", model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, "hi").toList();

    expect(backend.prompts.single.provider, "ollama-cloud");
    expect(backend.prompts.single.model, "qwen-2.5");
  });

  test("a chat's model is never paired with the app default's provider", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await savedChat(repo);

    pinChatModel(chat.state.id, model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, "hi").toList();

    expect(backend.prompts.single.model, "qwen-2.5");
    expect(backend.prompts.single.provider, isNull);
  });

  group("a draft chat", () {
    test("is nowhere on disk until it is saved", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      expect(config.chatDir(chat.state.id).existsSync(), isFalse);
      expect(await repo.listChats(), isEmpty);
      expect((await repo.openChat(chat.state.id)).state.id, chat.state.id);
    });

    // Writing meta.json would create the directory a draft exists to do
    // without, and leave it there whether or not the chat is ever used.
    test("what is pinned on it is held, and written with the first save", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.saveMeta(chat.state.id, ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
      expect(config.chatDir(chat.state.id).existsSync(), isFalse);
      expect((await repo.loadMeta(chat.state.id)).model, "qwen-2.5");

      await repo.save(chat);
      expect(ChatMeta.fromFile(config.metaFile(chat.state.id)).model, "qwen-2.5");
    });

    test("renaming one keeps it a draft", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.retitle(chat.state, "Named early");

      expect(await repo.listChats(), isEmpty);
      expect((await repo.openChat(chat.state.id)).state.title, "Named early");
    });
  });

  group("projects", () {
    test("a chat created in one is written under it when it is saved", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "work");

      expect(config.chatDir(chat.state.id, project: "work").existsSync(), isFalse);
      await repo.save(chat);

      expect(config.stateFile(chat.state.id, project: "work").existsSync(), isTrue);
      expect((await repo.listChats()).single.project, "work");
    });

    test("the turn is told which project's files it works in", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat(project: "work");
      await repo.save(chat);

      await repo.sendPrompt(chat.state.id, "hi").toList();

      expect(backend.prompts.single.project, "work");
    });

    // A draft is not on disk to be looked up, and its first turn is sent
    // before anything else has written it.
    test("a draft in a project says so before it is saved", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "work");

      expect(await repo.projectOf(chat.state.id), "work");
    });

    test("deleting a project drops the sessions of the chats in it", () async {
      final repo = repoWith(AppSettings());
      final kept = await repo.createChat();
      await repo.save(kept);
      final gone = await repo.createChat(project: "work");
      await repo.save(gone);

      await repo.deleteProject("work");

      expect((await repo.listChats()).single.id, kept.state.id);
      expect(backend.disposed, [gone.state.id]);
    });

    test("a moved chat's next turn runs in its new project", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat();
      await repo.save(chat);

      await repo.moveChat(chat.state.id, "work");
      await repo.sendPrompt(chat.state.id, "hi").toList();

      expect(backend.prompts.single.project, "work");
    });
  });

  // A rename that wrote the whole chat would put back the conversation it read.
  test("renaming writes the title without touching the conversation", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();
    await repo.save(chat);
    await repo.save(chat.copyWith(messages: [
      Message(id: "m1", role: MessageRole.user, createdAt: DateTime(2026)),
    ]));

    await repo.retitle(chat.state, "Named");

    final loaded = await repo.openChat(chat.state.id);
    expect(loaded.state.title, "Named");
    expect(loaded.messages, hasLength(1));
  });

  group("naming a chat", () {
    ChatRepository repoWithTitleModel() => repoWith(
        AppSettings(titleProviderId: "anthropic", titleModelId: "claude-haiku-3"));

    test("with no title model configured, nothing is asked", () async {
      final repo = repoWith(AppSettings());

      expect(await repo.suggestTitle("hello"), isNull);
      expect(backend.questions, isEmpty);
    });

    test("the title model is asked about the message, and cleaned up after", () async {
      final repo = repoWithTitleModel();
      backend.scriptedAnswer = '"Fixing the parser."';

      expect(await repo.suggestTitle("the parser is broken"), "Fixing the parser");
      expect(backend.questions.single.prompt, contains("the parser is broken"));
      expect(backend.questions.single.provider, "anthropic");
      expect(backend.questions.single.model, "claude-haiku-3");
    });

    test("a message with nothing in it is not worth a call", () async {
      final repo = repoWithTitleModel();

      expect(await repo.suggestTitle("   "), isNull);
      expect(backend.questions, isEmpty);
    });
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
