import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/builtin_project.dart" show AgentCapability;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/profile.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/project_settings.dart";
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
      expect(settings.sharedWorkspace, isFalse);
      // A watched turn: nothing is taken away beyond the built-in's (none).
      expect(settings.disabled, isEmpty);
      // The built-in ships its own note; the user's files are not read.
      expect(settings.bundledInstructions, contains("anonymous chat"));
      expect(settings.includesUserInstructions, isFalse);
    });

    test("an Omada-on project drops the task tool; an off one keeps it", () async {
      await repoWith(AppSettings()).createProject("team");
      Directory(config.projectDir(project: "team"))
          .createSync(recursive: true);
      // What the project settings page writes when Omada is flipped on.
      File(config
              .projectSettingsFile(project: "team"))
          .writeAsStringSync('{"omada": true}');
      await config.documents
          .hydrate([config.projectSettingsFile(project: "team")]);
      final repo = repoWith(AppSettings());
      final on = await repo.createChat(project: "team");
      await writeChatVia(repo, on);
      await repo.sendPrompt(on.state.id, userMessage("hi")).toList();
      final onSettings = backend.prompts.last.settings;
      expect(onSettings.omada, isTrue);
      expect(onSettings.disabled, contains(AgentCapability.task));

      final off = await repo.createChat();
      await writeChatVia(repo, off);
      await repo.sendPrompt(off.state.id, userMessage("hi")).toList();
      final offSettings = backend.prompts.last.settings;
      expect(offSettings.omada, isFalse);
      expect(offSettings.disabled, isEmpty);
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

    group("a rule written from a banner answer", () {
    test("\"Allow in Chat\" writes the derived rule on the chat's meta.json",
        () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "approval-1",
        ApprovalResponse.alwaysAllowChat,
        approval: ToolApproval(
            id: "approval-1",
            toolName: "bash",
            argumentsText: "git checkout -b foo"),
      );
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.permissions, hasLength(1));
      expect(meta.permissions.single.tool, "bash");
      expect(meta.permissions.single.pattern, "git checkout *");
      expect(meta.permissions.single.decision, PermissionDecision.allow);
      // The answer travels whole: the waiting turn derives the same rule
      // from the approval it holds, so the rest of the turn is covered too.
      expect(
          backend.approvals.single.response, ApprovalResponse.alwaysAllowChat);
    });

    test("\"Allow in Project\" writes the rule on the project's project.json",
        () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "approval-2",
        ApprovalResponse.alwaysAllowProject,
        approval: ToolApproval(
            id: "approval-2",
            toolName: "webfetch",
            argumentsText: "https://docs.example.com/guide"),
      );
      final settings = ProjectSettings.load(
          config,
          project: chat.state.project);
      expect(settings.permissions, hasLength(1));
      expect(settings.permissions.single.tool, "webfetch");
      expect(settings.permissions.single.pattern, "example.com");
      final chatMeta =
          await repo.loadMeta(chat.state.id);
      expect(chatMeta.permissions, isEmpty);
    });

    test("pressing Always twice on the same head does not stack the rule",
        () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      ToolApproval banner(String id) => ToolApproval(
          id: id,
          toolName: "bash",
          argumentsText: "cd repo && git log");
      await repo.respondApproval(chat.state.id, "a-1",
          ApprovalResponse.alwaysAllowChat, approval: banner("a-1"));
      await repo.respondApproval(chat.state.id, "a-2",
          ApprovalResponse.alwaysAllowChat, approval: banner("a-2"));
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.permissions, hasLength(1));
    });

    test("a re-prompt's Always in Chat grants the dirs, not a command rule",
        () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "d-1",
        ApprovalResponse.alwaysAllowChat,
        approval: ToolApproval(
            id: "d-1",
            toolName: "bash",
            argumentsText: "writing /home/yiannis/Projects/x",
            deniedDirs: const ["/home/yiannis/Projects/x"]),
      );
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, ["/home/yiannis/Projects/x"]);
      // No command rule: the prose varies every turn and would claim to
      // allow what it cannot name.
      expect(meta.permissions, isEmpty);
      expect(backend.approvals.single.response, ApprovalResponse.alwaysAllowChat);
    });

    test("a re-prompt's Always in Project grants the project's dirs", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "d-2",
        ApprovalResponse.alwaysAllowProject,
        approval: ToolApproval(
            id: "d-2",
            toolName: "bash",
            argumentsText: "writing /home/yiannis/Projects/y",
            deniedDirs: const ["/home/yiannis/Projects/y"]),
      );
      final settings = ProjectSettings.load(
          config,
          project: chat.state.project);
      expect(settings.writableDirs, ["/home/yiannis/Projects/y"]);
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, isEmpty);
    });

    test("the same dir twice is not stacked", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      Future<void> answer(String id) => repo.respondApproval(
            chat.state.id,
            id,
            ApprovalResponse.alwaysAllowChat,
            approval: ToolApproval(
                id: id,
                toolName: "bash",
                deniedDirs: const ["/home/yiannis/Projects/x"]),
          );
      await answer("d-3");
      await answer("d-4");
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, hasLength(1));
    });

    test("a plain allow writes nothing anywhere", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(chat.state.id, "approval-3",
          ApprovalResponse.allow,
          approval: ToolApproval(
              id: "approval-3",
              toolName: "bash",
              argumentsText: "python3 run.py"));
      final chatMeta =
          await repo.loadMeta(chat.state.id);
      expect(chatMeta.permissions, isEmpty);
    });

    test("the composed rules carry the tier they were read from", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.saveMeta(chat.state.id, ChatMeta(permissions: [
        const PermissionRule(
            tool: "bash",
            pattern: "chat rule *",
            decision: PermissionDecision.allow),
      ]));
      // The default project's rules, saved through the documents copy the
      // repository reads — a repo test's config hydrates nothing, so writing
      // the file alone would not be seen.
      await config.documents.write(
          config.projectSettingsFile(project: null), jsonEncode({
        "permissions": [
          {"tool": "bash", "pattern": "project rule *", "decision": "deny"},
        ],
      }));

      await repo.sendPrompt(chat.state.id, userMessage("go")).toList();

      final byPattern = {
        for (final r in backend.prompts.last.settings.permissions) r.pattern: r,
      };
      expect(byPattern["chat rule *"]!.origin, PermissionTier.chat);
      // The chat is in the default project, so its project settings and the
      // default project's are one file — the same read stamped twice, and
      // the app's stamp standing (the file is the default project's).
      expect(
          byPattern["project rule *"]!.origin, PermissionTier.defaultProject);
    });

    test("the rule the next turn reads covers the bare command", () async {
      // The live run's failure, pinned at the layer it happened: Always on a
      // command with no arguments derives `git status *`, and the next turn's
      // settings must carry a rule that matches the bare `git status` — the
      // pattern's trailing space is not a required one.
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "a-4",
        ApprovalResponse.alwaysAllowChat,
        approval: ToolApproval(
            id: "a-4",
            toolName: "bash",
            argumentsText: "git status"),
      );
      await repo.sendPrompt(chat.state.id, userMessage("again")).toList();

      final rules = backend.prompts.last.settings.permissions;
      expect(rules.map((r) => r.pattern), contains("git status *"));
    });

    test("a re-prompt's denied FILE path lands in writableDirs", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "d-5",
        ApprovalResponse.alwaysAllowProject,
        approval: ToolApproval(
            id: "d-5",
            toolName: "bash",
            argumentsText: "writing /etc/hosts",
            deniedDirs: const ["/etc/hosts"]),
      );
      // A denial report names the exact path the write touched, often a
      // file: the grant records it as it is, and the helper grants file
      // rights on it.
      final settings = ProjectSettings.load(config, project: chat.state.project);
      expect(settings.writableDirs, ["/etc/hosts"]);
    });
  });
}
