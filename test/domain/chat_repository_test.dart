import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/profile.dart";
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
          libraryFor: library == null ? null : (_) => library);



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

  group("creating one", () {
    test("writes it, and lists it, straight away", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat();

      expect(File(config.stateFile(chat.state.id)).existsSync(), isTrue);
      expect((await repo.listChats()).single.id, chat.state.id);
      expect((await repo.openChat(chat.state.id)).state.id, chat.state.id);
    });

    // What the caller decided before there was a chat to hang it on: the
    // reminder pinning `approveMode`, and the new-chat screen's settings page.
    test("the settings it is handed land with it", () async {
      final repo = repoWith(AppSettings());

      final chat = await repo.createChat(
          meta: ChatMeta(provider: "ollama-cloud", model: "qwen-2.5"));

      expect((await repo.loadMeta(chat.state.id)).model, "qwen-2.5");
      expect(ChatMeta.parse(File(config.metaFile(chat.state.id)).readAsStringSync()).model,
          "qwen-2.5");
    });

    // Written before the meta, or the store files the meta under the default
    // project whatever the chat says.
    test("one made in a project is written under it", () async {
      final repo = repoWith(AppSettings());

      final chat = await repo.createChat(
          project: "work", meta: ChatMeta(model: "qwen-2.5"));

      expect(File(config.stateFile(chat.state.id, project: "work")).existsSync(), isTrue);
      expect(File(config.metaFile(chat.state.id, project: "work")).existsSync(), isTrue);
      expect((await repo.listChats()).single.project, "work");
    });

    test("renaming one keeps everything else it says", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "work");

      await repo.retitle(chat.state.id, "Named early");

      expect((await repo.listChats()).single.title, "Named early");
      expect((await repo.openChat(chat.state.id)).state.project, "work");
    });
  });

  group("projects", () {
    test("the turn is told which project's files it works in", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat(project: "work");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      expect(backend.prompts.single.settings.project, "work");
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

    // A built-in project is a directory the app ships rather than the user
    // makes. A chat can be in one, but its name cannot be created or deleted,
    // and a turn in it is resolved against its spec: no profile, no memory, no
    // workspace it shares with another chat.
    test("a built-in project's name cannot be created or deleted", () async {
      final repo = repoWith(AppSettings());

      // `createProject` throws before it returns a future; `deleteProject` is
      // async, so its refusal is a future error.
      expect(() => repo.createProject("anonymous"), throwsArgumentError);
      await expectLater(repo.deleteProject("anonymous"), throwsArgumentError);
      expect(() => repo.createProject("byte-repair"), throwsArgumentError);
      await expectLater(repo.deleteProject("byte-repair"), throwsArgumentError);
    });

    test("a turn in Byte Repair keeps the profile, memory and shared workspace",
        () async {
      final repo = repoWith(AppSettings(
        profile: const Profile(name: "Tea Fan"),
        autoMemory: true,
      ));
      final chat = await repo.createChat(project: "byte-repair");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, "byte-repair");
      // Byte Repair inherits the app's profile and memory, unlike Anonymous.
      expect(settings.profile, isNotNull);
      expect(settings.memory.autoMemory, isTrue);
      expect(settings.sharedWorkspace, isTrue);
      expect(settings.disabled, isEmpty);
      // It ships its own note about secure coding and ESBMC, and reads the
      // user's instruction files on top of it.
      expect(settings.bundledInstructions, contains("ESBMC"));
      expect(settings.includesUserInstructions, isTrue);
    });

    test("a turn in a built-in project drops the profile and memory", () async {
      final repo = repoWith(AppSettings(
        profile: const Profile(name: "Tea Fan"),
        autoMemory: true,
      ));
      final chat = await repo.createChat(project: "anonymous");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, "anonymous");
      // The app's profile is set, but the built-in says none.
      expect(settings.profile, isNull);
      // Auto-memory is on in the app, but the built-in says off.
      expect(settings.memory.autoMemory, isFalse);
      // No shared workspace: the chat's own is its HOME too.
      expect(settings.sharedWorkspace, isFalse);
      // A watched turn: nothing is taken away beyond the built-in's (none).
      expect(settings.disabled, isEmpty);
      // The built-in ships its own note; the user's files are not read.
      expect(settings.bundledInstructions, contains("anonymous chat"));
      expect(settings.includesUserInstructions, isFalse);
    });

    // A draft is not on disk, so it answers for its own project: the same
    // resolution a saved chat gets, before anything has written it.
    test("a draft in a built-in project resolves before it is saved", () async {
      final repo = repoWith(AppSettings(
        profile: const Profile(name: "Tea Fan"),
      ));
      final chat = await repo.createChat(project: "anonymous");

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, "anonymous");
      expect(settings.profile, isNull);
      expect(settings.sharedWorkspace, isFalse);
    });

    test("the default project keeps the app's profile and memory", () async {
      final repo = repoWith(AppSettings(
        profile: const Profile(name: "Tea Fan"),
        autoMemory: true,
      ));
      final chat = await repo.createChat();
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, isNull);
      expect(settings.profile, isNotNull);
      expect(settings.memory.autoMemory, isTrue);
      expect(settings.sharedWorkspace, isTrue);
      // A user's project reads its files; nothing ships in their place.
      expect(settings.bundledInstructions, isNull);
      expect(settings.includesUserInstructions, isFalse);
    });

    test("a move ends the shell the chat stood in, and only that one", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat();
      await writeChatVia(repo, chat);

      await repo.moveChat(chat.state.id, "work");

      expect(backend.closedShells, [(chat.state.id, null)]);
      expect(backend.disposed, isEmpty);
    });

    // A chat moved out of Byte Repair runs its next turn under the project it
    // went to: the note is resolved per turn from where the chat now is, so
    // nothing of the built-in travels with the chat.
    test("a moved chat's next turn leaves the built-in's note behind", () async {
      final repo = repoWith(AppSettings(profile: const Profile(name: "Tea Fan")));
      final chat = await repo.createChat(project: "byte-repair");
      await writeChatVia(repo, chat);

      await repo.moveChat(chat.state.id, "work");
      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, "work");
      expect(settings.bundledInstructions, isNull);
    });

    // A turn still running holds the directories that are about to move; the
    // next command it ran would quietly remake them under the project it left.
    test("a move ends a running turn before it moves anything", () async {
      final repo = repoWith(AppSettings(defaultProviderId: "anthropic"));
      final chat = await repo.createChat();
      await writeChatVia(repo, chat);
      backend.hold = Completer<void>();
      final turn = repo.sendPrompt(chat.state.id, userMessage("hi")).toList();
      await pumpEventQueue();

      await repo.moveChat(chat.state.id, "work");
      backend.hold!.complete();
      await turn;

      expect(backend.aborted, [chat.state.id]);
      expect(backend.closedShells, [(chat.state.id, null)]);
      expect(backend.runningTurns.value, isEmpty);
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

  // An anonymous chat ships a 24h TTL rather than the app default, but a chat's
  // own override still wins, the way it does for any project.
  group("an anonymous chat's TTL", () {
    test("defaults to 24h even with the app default off", () async {
      final repo = repoWith(AppSettings()); // app default is off
      final chat = await repo.createChat(project: "anonymous");

      final anchored = await repo.saveState(chat.state);

      expect(anchored.tempTtlSince, isNotNull);
      expect(
        anchored.tempTtlExpiresAt!.difference(anchored.tempTtlSince!),
        const Duration(hours: 24),
      );
    });

    test("a per-chat override still wins", () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "anonymous");
      await repo.saveMeta(chat.state.id, ChatMeta(tempChatTtl: TempChatTtl.off));

      final anchored = await repo.saveState(chat.state);

      expect(anchored.tempTtlSince, isNull);
      expect(anchored.tempTtlExpiresAt, isNull);
    });
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
            CompletionKind.skill, "review", "---\ndescription: d\n---\n\nLook at it."),
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

  /// The sync layer's whole view of this device. Mirroring is proven end to
  /// end in `sync_hub_pair_test.dart`; what is here is the two arms that
  /// pairing never reaches — a chat moved between projects, and its own
  /// overrides changing.
  group("the change feed", () {
    test("reports what was appended, to which chat", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);

      final record =
          ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done);
      await repo.append(chat.state.id, [record]);
      await pumpEventQueue();

      final event = seen.whereType<Appended>().single;
      expect(event.chatId, chat.state.id);
      expect(event.records, [record]);
    });

    test("a retitle is a state change carrying the new state", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);

      await repo.retitle(chat.state.id, "Renamed");
      await pumpEventQueue();

      expect(seen.whereType<StateChanged>().last.state.title, "Renamed");
    });

    test("a chat's own overrides are their own event", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);

      await repo.saveMeta(chat.state.id, ChatMeta(model: "qwen-2.5"));
      await pumpEventQueue();

      final event = seen.whereType<MetaChanged>().single;
      expect(event.chatId, chat.state.id);
      expect(event.meta.model, "qwen-2.5");
    });

    test("a move says where the chat went", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);

      await repo.moveChat(chat.state.id, "work");
      await pumpEventQueue();

      final event = seen.whereType<Moved>().single;
      expect(event.chatId, chat.state.id);
      expect(event.project, "work");
    });

    test("a delete names the chat that is gone", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);

      await repo.deleteChat(chat.state.id);
      await pumpEventQueue();

      expect(seen.whereType<Deleted>().single.chatId, chat.state.id);
    });
  });
}
