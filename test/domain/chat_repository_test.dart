import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late Directory tmp;
  late FakeBackend backend;

  late AppConfig config;

  ChatRepository repoWith(AppSettings settings, {PromptLibrary? library}) =>
      ChatRepository(FileChatStore(config), backend, () => settings, config,
          library: library);



  /// A chat that is on disk, the way one is by the time a prompt is sent.
  Future<Chat> savedChat(ChatRepository repo) async {
    final chat = await repo.createChat();
    await writeChatVia(repo, chat);
    return chat;
  }

  /// What the chat settings page would have written.
  void pinChatModel(String chatId, {String? provider, String? model}) {
    Directory(config.chatDir(chatId)).createSync(recursive: true);
    File(config.metaFile(chatId))
        .writeAsStringSync(ChatMeta(provider: provider, model: model).encode());
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_repo_test_");
    config = AppConfig.forDirectory(tmp.path, fileSystemIo);
    Directory(config.chatsDir()).createSync(recursive: true);
    backend = FakeBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test("a chat without its own model runs on the app default", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await repo.createChat();

    await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

    expect(backend.prompts.single.settings.provider, "anthropic");
    expect(backend.prompts.single.settings.model, "claude-sonnet-4");
  });

  test("a chat's own model wins over the app default", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await savedChat(repo);

    pinChatModel(chat.state.id, provider: "ollama-cloud", model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

    expect(backend.prompts.single.settings.provider, "ollama-cloud");
    expect(backend.prompts.single.settings.model, "qwen-2.5");
  });

  test("a chat's model is never paired with the app default's provider", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await savedChat(repo);

    pinChatModel(chat.state.id, model: "qwen-2.5");

    await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

    expect(backend.prompts.single.settings.model, "qwen-2.5");
    expect(backend.prompts.single.settings.provider, isNull);
  });

  // A turn carried on runs under whatever the chat is set to now, resolved the
  // same way — not under whatever it was when the turn was cut off.
  test("carrying a turn on resolves the same settings a prompt would", () async {
    final repo = repoWith(AppSettings(defaultProviderId: "anthropic", defaultModelId: "claude-sonnet-4"));
    final chat = await savedChat(repo);

    pinChatModel(chat.state.id, provider: "ollama-cloud", model: "qwen-2.5");

    await repo.resumeTurn(chat.state.id).toList();

    expect(backend.resumes.single.settings.provider, "ollama-cloud");
    expect(backend.resumes.single.settings.model, "qwen-2.5");
  });

  group("a draft chat", () {
    test("is nowhere on disk until it is saved", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      expect(Directory(config.chatDir(chat.state.id)).existsSync(), isFalse);
      expect(await repo.listChats(), isEmpty);
      expect((await repo.openChat(chat.state.id)).state.id, chat.state.id);
    });

    // Writing meta.json would create the directory a draft exists to do
    // without, and leave it there whether or not the chat is ever used.
    test("what is pinned on it is held, and written with the first save", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.saveMeta(chat.state.id, ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));
      expect(Directory(config.chatDir(chat.state.id)).existsSync(), isFalse);
      expect((await repo.loadMeta(chat.state.id)).model, "qwen-2.5");

      await writeChatVia(repo, chat);
      expect(ChatMeta.parse(File(config.metaFile(chat.state.id)).readAsStringSync()).model,
          "qwen-2.5");
    });

    test("renaming one keeps it a draft", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      await repo.retitle(chat.state.id, "Named early");

      expect(await repo.listChats(), isEmpty);
      expect((await repo.openChat(chat.state.id)).state.title, "Named early");
    });
  });

  group("projects", () {
    test("a chat created in one is written under it when it is saved", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "work");

      expect(Directory(config.chatDir(chat.state.id, project: "work")).existsSync(), isFalse);
      await writeChatVia(repo, chat);

      expect(File(config.stateFile(chat.state.id, project: "work")).existsSync(), isTrue);
      expect((await repo.listChats()).single.project, "work");
    });

    test("the turn is told which project's files it works in", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat(project: "work");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.project, "work");
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
      await writeChatVia(repo, kept);
      final gone = await repo.createChat(project: "work");
      await writeChatVia(repo, gone);

      await repo.deleteProject("work");

      expect((await repo.listChats()).single.id, kept.state.id);
      expect(backend.disposed, [gone.state.id]);
    });

    test("a moved chat's next turn runs in its new project", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat();
      await writeChatVia(repo, chat);

      await repo.moveChat(chat.state.id, "work");
      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.project, "work");
    });
  });

  // A rename that wrote the whole chat would put back the conversation it read.
  test("renaming writes the title without touching the conversation", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();
    await writeChatVia(repo, chat);
    await writeChatVia(repo, chat.copyWith(messages: [
      Message(id: "m1", role: MessageRole.user, createdAt: DateTime(2026)),
    ]));

    await repo.retitle(chat.state.id, "Named");

    final loaded = await repo.openChat(chat.state.id);
    expect(loaded.state.title, "Named");
    expect(loaded.messages, hasLength(1));
  });

  // The namer holds the state from before the turn it is naming, and writing
  // that back used to undo the anchor the turn's own save had just made — so a
  // temporary chat that got named lost its hourglass until a second turn.
  test("renaming keeps the TTL anchor the turn wrote", () async {
    final repo = repoWith(AppSettings(tempChatTtl: TempChatTtl.hours24));
    final chat = await repo.createChat();
    final anchored = await repo.saveState(chat.state);
    expect(anchored.tempTtlExpiresAt, isNotNull);

    await repo.retitle(chat.state.id, "Named");

    final loaded = await repo.openChat(chat.state.id);
    expect(loaded.state.title, "Named");
    expect(loaded.state.tempTtlSince, anchored.tempTtlSince);
    expect(loaded.state.tempTtlExpiresAt, anchored.tempTtlExpiresAt);
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
    final file = parts.single as FilePart;

    expect(file.filename, "notes.txt");
    expect(file.mimeType, "text/plain");
    expect(await repo.readResource(chat.state.id, file.resource), [104, 105]);
    expect(Directory(config.resourcesDir(chat.state.id)).listSync(), hasLength(1));
  });

  // The library is user-editable files, so what a reference meant has to be
  // written down as the message is composed rather than looked up again when
  // the turn is replayed.
  test("a composed prompt records what its references meant", () async {
    final repo = repoWith(
      AppSettings(),
      library: PromptLibrary([
        PromptDocument.parse(
            CompletionKind.command, "review", "---\ndescription: d\n---\n\nLook at it."),
      ]),
    );

    final prompt = repo.composeUserPrompt("/review the parser");

    expect(prompt.plainText, "/review the parser");
    expect(prompt.documents, {"/review": "Look at it."});
  });

  test("a reference the library does not know records nothing", () async {
    final repo = repoWith(AppSettings());

    expect(repo.composeUserPrompt("/etc/hosts is where?").documents, isEmpty);
  });

  test("a resource that has gone reads back as nothing", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat();

    expect(await repo.readResource(chat.state.id, "gone.txt"), isNull);
  });
}
