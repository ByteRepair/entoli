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
import "package:agent_chat/domain/builtin_project.dart"
    show AgentCapability, myTeamNote;
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

    /// A seeded turn in [project]; the settings the turn resolved.
    turnSettings(String? project) async {
      final repo = repoWith(AppSettings(
        profile: const Profile(name: "Tea Fan"),
        autoMemory: true,
      ));
      final chat = await repo.createChat(project: project);
      await writeChatVia(repo, chat);
      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();
      return backend.prompts.last.settings;
    }

    test("what a turn carries comes from the project's spec", () async {
      // Byte Repair inherits the app's profile and memory, unlike Anonymous,
      // and shares the workspace.
      final br = await turnSettings("byte-repair");
      expect(br.project, "byte-repair");
      expect(br.profile, isNotNull);
      expect(br.memory.autoMemory, isTrue);
      expect(br.sharedWorkspace, isTrue);
      expect(br.disabled, isEmpty);
      // It ships its own note about secure coding and ESBMC, and reads the
      // user's instruction files on top of it.
      expect(br.bundledInstructions, contains("ESBMC"));
      expect(br.includesUserInstructions, isTrue);

      // Anonymous: the app's profile is set, but the built-in says none.
      final anon = await turnSettings("anonymous");
      expect(anon.project, "anonymous");
      expect(anon.profile, isNull);
      expect(anon.memory.autoMemory, isFalse);
      expect(anon.sharedWorkspace, isFalse);
      // A watched turn: nothing is taken away beyond the built-in's (none).
      expect(anon.disabled, isEmpty);
      // The built-in ships its own note; the user's files are not read.
      expect(anon.bundledInstructions, contains("anonymous chat"));
      expect(anon.includesUserInstructions, isFalse);

      // The default project keeps the app's profile and memory, and reads
      // its files; nothing ships in their place.
      final def = await turnSettings(null);
      expect(def.project, isNull);
      expect(def.profile, isNotNull);
      expect(def.memory.autoMemory, isTrue);
      expect(def.sharedWorkspace, isTrue);
      expect(def.bundledInstructions, isNull);
      expect(def.includesUserInstructions, isFalse);
    });

    test("Landlock: the project's answer over the app's, unset is on",
        () async {
      expect((await (await turnSettings("byte-repair")).policy()).sandboxed, isTrue);
      await config.documents
          .write(config.projectSettingsFile(), '{"sandbox": false}');
      expect((await (await turnSettings("byte-repair")).policy()).sandboxed, isFalse);
      await config.documents.write(
          config.projectSettingsFile(project: "byte-repair"),
          '{"sandbox": true}');
      expect((await (await turnSettings("byte-repair")).policy()).sandboxed, isTrue);
    });

    test("an Omada-on project drops the task tool; an off one keeps it", () async {
      await repoWith(AppSettings()).createProject("team");
      // What the project settings page writes when Omada is flipped on.
      await config.documents
          .write(config.projectSettingsFile(project: "team"), '{"omada": true}');
      final repo = repoWith(AppSettings());
      final on = await repo.createChat(project: "team");
      await writeChatVia(repo, on);
      await repo.sendPrompt(on.state.id, userMessage("hi")).toList();
      final onSettings = backend.prompts.last.settings;
      expect(onSettings.bundledInstructions, myTeamNote);
      expect(onSettings.disabled, contains(AgentCapability.task));
      expect(onSettings.omada, isTrue);

      final off = await repo.createChat();
      await writeChatVia(repo, off);
      await repo.sendPrompt(off.state.id, userMessage("hi")).toList();
      final offSettings = backend.prompts.last.settings;
      expect(offSettings.bundledInstructions, isNull);
      expect(offSettings.disabled, isEmpty);
      expect(offSettings.omada, isFalse);
    });

    test("an Omada-on user project runs under My Team's note, files read on top",
        () async {
      await repoWith(AppSettings()).createProject("team");
      await config.documents
          .write(config.projectSettingsFile(project: "team"), '{"omada": true}');
      Directory(config.projectWorkspaceDir(project: "team"))
          .createSync(recursive: true);
      File(config.fs.path
              .join(config.projectWorkspaceDir(project: "team"), "AGENTS.md"))
          .writeAsStringSync("team rules");
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "team");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      // The room contract is My Team's, resolved through the Omada answer,
      // with the user's files read after it. The rendering itself is the
      // backend's, covered by its bundled-note test.
      expect(settings.bundledInstructions, myTeamNote);
      expect(settings.includesUserInstructions, isTrue);
    });

    test("an Omada-off project ships no note and reads its files alone",
        () async {
      await repoWith(AppSettings()).createProject("plain");
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "plain");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.bundledInstructions, isNull);
      expect(settings.includesUserInstructions, isFalse);
    });

    test("a turn in My Team runs the room note and drops the task tool",
        () async {
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "my-team");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.project, "my-team");
      expect(settings.disabled, contains(AgentCapability.task));
      expect(settings.bundledInstructions, myTeamNote);
      expect(settings.includesUserInstructions, isTrue);
    });

    test("a project.json omada flag cannot turn Omada on in a built-in",
        () async {
      // The file is what a user project's toggle writes; a built-in's answer
      // is its spec, so a stray one there must not be read.
      Directory(config.projectDir(project: "anonymous"))
          .createSync(recursive: true);
      await config.documents.write(
          config.projectSettingsFile(project: "anonymous"), '{"omada": true}');
      final repo = repoWith(AppSettings());
      final chat = await repo.createChat(project: "anonymous");
      await writeChatVia(repo, chat);

      await repo.sendPrompt(chat.state.id, userMessage("hi")).toList();

      final settings = backend.prompts.single.settings;
      expect(settings.disabled, isEmpty);
      // Its own note still stands, not My Team's.
      expect(settings.bundledInstructions, contains("anonymous chat"));
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
    final chat = await repo.createChat(project: "work");
    await writeChatVia(repo, chat);
    await writeChatVia(repo, chat.copyWith(messages: [
      Message(id: "m1", role: MessageRole.user, createdAt: DateTime(2026)),
    ]));

    await repo.retitle(chat.state.id, "Named");

    final loaded = await repo.openChat(chat.state.id);
    expect(loaded.state.title, "Named");
    // Everything else the chat says stands: where it is, its conversation,
    // and the row the list shows.
    expect(loaded.state.project, "work");
    expect(loaded.messages, hasLength(1));
    expect((await repo.listChats()).single.title, "Named");
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
    /// A saved chat with the feed already listening over it.
    Future<({String chatId, List<RepoEvent> seen, ChatRepository repo})>
        watchIt() async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final seen = <RepoEvent>[];
      repo.changes.listen(seen.add);
      return (repo: repo, chatId: chat.state.id, seen: seen);
    }

    test("reports what the change feed carries", () async {
      final record = ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done);

      // What was appended, to which chat.
      var feed = await watchIt();
      await feed.repo.append(feed.chatId, [record]);
      await pumpEventQueue();
      expect(feed.seen.whereType<Appended>().single.chatId, feed.chatId);
      expect(feed.seen.whereType<Appended>().single.records, [record]);

      // A retitle is a state change carrying the new state.
      feed = await watchIt();
      await feed.repo.retitle(feed.chatId, "Renamed");
      await pumpEventQueue();
      expect(feed.seen.whereType<StateChanged>().last.state.title, "Renamed");

      // A chat's own overrides are their own event.
      feed = await watchIt();
      await feed.repo.saveMeta(feed.chatId, ChatMeta(model: "qwen-2.5"));
      await pumpEventQueue();
      expect(feed.seen.whereType<MetaChanged>().single.chatId, feed.chatId);
      expect(feed.seen.whereType<MetaChanged>().single.meta.model, "qwen-2.5");

      // A move says where the chat went.
      feed = await watchIt();
      await feed.repo.moveChat(feed.chatId, "work");
      await pumpEventQueue();
      expect(feed.seen.whereType<Moved>().single.chatId, feed.chatId);
      expect(feed.seen.whereType<Moved>().single.project, "work");

      // A delete names the chat that is gone.
      feed = await watchIt();
      await feed.repo.deleteChat(feed.chatId);
      await pumpEventQueue();
      expect(feed.seen.whereType<Deleted>().single.chatId, feed.chatId);
    });
  });

  test("a turn's policy reads the settings as they are now, not as the turn "
      "began", () async {
    final repo = repoWith(AppSettings());
    final chat = await repo.createChat(project: "work");
    await writeChatVia(repo, chat);
    await repo.sendPrompt(chat.state.id, userMessage("go")).toList();
    final policy = backend.prompts.last.settings.policy;
    expect((await policy()).permissions, isEmpty);
    expect(backend.prompts.last.settings.approveMode, isNull,
        reason: "nothing pins the mode, so the turn reads the chat's live");
    expect((await policy()).approveMode, ApproveMode.auto);

    const podman = PermissionRule(
        tool: "bash", pattern: "podman *", decision: PermissionDecision.allow);
    await (ProjectSettings.load(config, project: "work")
          ..permissions = [podman]
          ..writableDirs = ["~/.local/share"])
        .save(config, project: "work");
    await (ProjectSettings.load(config)..sandbox = false).save(config);
    await repo.saveMeta(chat.state.id, ChatMeta(approveMode: ApproveMode.never));

    final now = await policy();
    expect(now.permissions, [podman]);
    expect(now.permissions.single.origin, PermissionTier.project);
    expect(now.writableDirs, ["~/.local/share"]);
    expect(now.sandboxed, isFalse);
    expect(now.approveMode, ApproveMode.never);

    await repo.saveMeta(chat.state.id, ChatMeta(sandbox: true));
    expect((await policy()).sandboxed, isTrue,
        reason: "the chat's own answer is over the project's");
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
      // The standing answer is the webfetch star: one approval covers the
      // fetch tool and the fetcher commands alike, whatever host each one
      // names next.
      expect(settings.permissions.single.tool, "webfetch");
      expect(settings.permissions.single.pattern, "*");
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

    test("a re-prompt's dir grant lands in the tier the answer named", () async {
      ToolApproval asked(String id, String dir) => ToolApproval(
          id: id, toolName: "bash", argumentsText: "writing $dir",
          deniedDirs: [dir]);

      // Always in Chat: the chat's dirs, granted once.
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(chat.state.id, "d-1",
          ApprovalResponse.alwaysAllowChat,
          approval: asked("d-1", "/home/yiannis/Projects/x"));
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, ["/home/yiannis/Projects/x"]);
      // No command rule: the prose varies every turn and would claim to
      // allow what it cannot name.
      expect(meta.permissions, isEmpty);
      expect(backend.approvals.single.response, ApprovalResponse.alwaysAllowChat);

      // Always in Project: the project's dirs, and not the chat's.
      final other = repoWith(AppSettings());
      final projected = await savedChat(other);
      await other.respondApproval(projected.state.id, "d-2",
          ApprovalResponse.alwaysAllowProject,
          approval: asked("d-2", "/home/yiannis/Projects/y"));
      final settings = ProjectSettings.load(
          config,
          project: projected.state.project);
      expect(settings.writableDirs, ["/home/yiannis/Projects/y"]);
      expect((await other.loadMeta(projected.state.id)).writableDirs, isEmpty);
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

    test("add_directory's always answer lands in the tier's writableDirs",
        () async {
      // The grant request carries its directory in `deniedDirs`: dirs,
      // never a rule.
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(chat.state.id, "ad-1",
          ApprovalResponse.alwaysAllowChat,
          approval: ToolApproval(
              id: "ad-1",
              toolName: "add_directory",
              argumentsText: "/home/yiannis",
              deniedDirs: const ["/home/yiannis"]));
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, ["/home/yiannis"]);
      expect(meta.permissions, isEmpty);
    });

    test("a re-prompt naming the app's own data persists nothing", () async {
      // The tool's door refuses the data tree before any banner; this is the
      // re-prompt's door, filtered where the answer would outlive the turn.
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      final inside = "${config.dataDir}/projects";
      await repo.respondApproval(chat.state.id, "ad-2",
          ApprovalResponse.alwaysAllowChat,
          approval: ToolApproval(
              id: "ad-2",
              toolName: "add_directory",
              argumentsText: inside,
              deniedDirs: [inside]));
      final meta = await repo.loadMeta(chat.state.id);
      expect(meta.writableDirs, isEmpty);
      expect(meta.permissions, isEmpty);
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
        for (final r in (await backend.prompts.last.settings.policy()).permissions)
          r.pattern: r,
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

      final rules = (await backend.prompts.last.settings.policy()).permissions;
      expect(rules.map((r) => r.pattern), contains("git status *"));
    });

    test("Always on leaving the sandbox writes a no-sandbox rule for the "
        "command's words", () async {
      final repo = repoWith(AppSettings());
      final chat = await savedChat(repo);
      await repo.respondApproval(
        chat.state.id,
        "d-6",
        ApprovalResponse.alwaysAllowProject,
        approval: const ToolApproval(
            id: "d-6",
            toolName: "bash",
            argumentsText: "podman version 2>&1 | head -5",
            unsandboxed: true),
      );
      final settings = ProjectSettings.load(config, project: chat.state.project);
      final rule = settings.permissions.single;
      expect(rule.pattern, "podman version *");
      expect(rule.unconfined, isTrue);
      expect(rule.decision, isNull,
          reason: "the asking is left to whatever already decides it");
    });
  });
}
