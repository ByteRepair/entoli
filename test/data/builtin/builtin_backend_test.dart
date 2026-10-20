import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "dart:convert";

import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/builtin_backend.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/llm_registry.dart";
import "package:agent_chat/data/builtin/memory/instructions.dart"
    show InstructionFile, renderInstructions;
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/data/builtin/participants_tool.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/local/file_sub_agent_log.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "../../harness.dart";
import "builtin_fakes.dart";

void main() {
  const chatId = "chat-1";
  final sentAt = DateTime(2026);
  late AppConfig config;
  late FakeLlmClient client;
  late FakeShell shell;
  late List<LlmProviderConfig> providers;

  final finish = saidOnly("done");
  ShellResult okEmpty(String command) => ok("");

  setUp(() {
    config = tempConfig("agent_chat_builtin_");
    providers = const [
      LlmProviderConfig(
        id: "fake",
        api: LlmApi.openai,
        baseUrl: "https://example.test/v1",
        models: ["fake-model"],
        defaultModelId: "fake-model",
      ),
    ];
  });

  BuiltinBackend backendOver(
    List<List<LlmChunk>> turns, {
    ShellResult Function(String)? respond,
    PromptLibrary? library,
    BuiltinOptions options = const BuiltinOptions(),
    LlmClient? judge,
  }) {
    client = FakeLlmClient(turns);
    shell = FakeShell(respond ?? okEmpty);
    final backend = BuiltinBackend(
      config: config,
      shell: shell,
      webSearch: FakeWebSearch(),
      store: FileChatStore(config),
      options: options,
      registry: LlmRegistry(
        endpoints: () => [
          for (final p in providers) LlmEndpoint(p, build: (_, _) => client),
          if (judge != null)
            LlmEndpoint(
                const LlmProviderConfig(
                    id: "judge",
                    api: LlmApi.openai,
                    baseUrl: "https://judge.test/v1",
                    models: ["judge-model"],
                    defaultModelId: "judge-model"),
                build: (_, _) => judge),
        ],
        lookupEnv: (_) => null,
        lookupKey: (_) => null,
      ),
    );
    if (library != null) backend.setLibrary(null, library);
    return backend;
  }

  /// Most of these are not about approvals, so the default here is the chat
  /// setting that does not stop to ask.
  /// The message is dated [sentAt] rather than by the clock, because what the
  /// model is shown of a user turn carries the date it was sent — so a test
  /// comparing a live session against one rebuilt from a log has to date both
  /// the same. [documents] is what the turn's `/command` and `@agent`
  /// references meant, the way the app records them when it composes.
  Future<List<AgentEvent>> send(
    BuiltinBackend backend,
    String text, {
    String? model = "fake-model",
    String? provider = "fake",
    String? project,
    bool sharedWorkspace = true,
    Set<AgentCapability> disabled = const {},
    List<Message> history = const [],
    List<MessagePart> files = const [],
    Map<String, String> documents = const {},
    DateTime? at,
    MemorySettings memory = MemorySettings.off,
    String? bundledInstructions,
    bool includesUserInstructions = false,
    ApproveMode approveMode = ApproveMode.never,
    List<PermissionRule> permissions = const [],
    String? omadaMember,
    bool omada = false,
  }) =>
      backend
          .sendPrompt(
              chatId,
              userMessage(text,
                  at: at ?? sentAt, documents: documents, files: files),
              history: history,
              settings: TurnSettings(
                  model: model,
                  provider: provider,
                  project: project,
                  approveMode: approveMode,
                  permissions: permissions,
                  memory: memory,
                  sharedWorkspace: sharedWorkspace,
                  disabled: disabled,
                  bundledInstructions: bundledInstructions,
                  includesUserInstructions: includesUserInstructions,
                  omadaMember: omadaMember,
                  omada: omada))
          .toList();

  /// Carrying on the turn [history] ends in, under the same settings [send]
  /// uses.
  Future<List<AgentEvent>> resuming(BuiltinBackend backend, List<Message> history) =>
      backend
          .resumeTurn(chatId,
              history: history,
              settings: const TurnSettings(
                  model: "fake-model", provider: "fake", approveMode: ApproveMode.never))
          .toList();

  /// A turn left running for the test to answer, whether what it stops on is a
  /// command to approve or a question to pick from.
  Stream<AgentEvent> asking(BuiltinBackend backend, String text,
          {ApproveMode approveMode = ApproveMode.ask}) =>
      backend.sendPrompt(chatId, userMessage(text, at: sentAt),
          settings: TurnSettings(
              model: "fake-model", provider: "fake", approveMode: approveMode));

  group("picking where the turn runs", () {
    test("a chat with no provider is told to configure one", () async {
      final backend = backendOver([]);
      final events = await send(backend, "hi", provider: null, model: null);

      expect(events.whereType<ErrorEvent>().single.message, contains("No model is selected"));
      expect(events.last, isA<DoneEvent>());
    });

    test("an Omada-on turn withholds the task tool and runs the room note", () async {
      final backend = backendOver([
        [finish],
      ]);

      await send(backend, "hi",
          disabled: {AgentCapability.task},
          bundledInstructions: myTeamNote,
          includesUserInstructions: true);

      // The capability mechanism drops `task` from the tool list; the room
      // contract is the turn's instructions, resolved in the repository and
      // rendered under it.
      final tools = client.calls.single.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("task")));
      final turnMessage = client.sent.first[1].text;
      expect(turnMessage, contains(myTeamNote!));
    });

    test("an omada turn offers the roster from the project's library, and a "
        "direct one offers nothing", () async {
      final library = PromptLibrary([
        PromptDocument.parse(CompletionKind.agent, "explore",
            "---\ndescription: Fast explorer\n---\nYou explore."),
      ]);
      final room = backendOver([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ], library: library);
      final events = await send(room, "hi", omada: true, project: "Team");

      expect(
          client.calls.first.tools.map((t) => t.name), contains(listParticipantsToolName));
      // The roster is the project's agent library, resolved where the turn
      // is composed to run.
      expect(events.whereType<ToolResultEvent>().single.result.output,
          contains("@explore — Fast explorer"));
      expect(events.whereType<ToolResultEvent>().single.result.output,
          isNot(contains("@general")));

      final direct = backendOver([[finish]], library: library);
      await send(direct, "hi");
      expect(
          client.calls.first.tools.map((t) => t.name),
          isNot(contains(listParticipantsToolName)));
    });

    test("a member's turn is told its own handle", () async {
      final library = PromptLibrary([
        PromptDocument.parse(CompletionKind.agent, "explore",
            "---\ndescription: Fast explorer\n---\nYou explore."),
      ]);
      final room = backendOver([[finish]], library: library);
      await send(room, "hi",
          omada: true, project: "Team", omadaMember: "explore");

      expect(client.sent.first[1].text,
          contains("You are @explore, a member of this team.\n\nYou explore."));
    });

    test("a turn outside Omada still offers the task tool", () async {
      final backend = backendOver([
        [finish],
      ]);

      await send(backend, "hi");

      final tools = client.calls.single.tools.map((t) => t.name).toSet();
      expect(tools, contains("task"));
      // No note was handed, so nothing of the room reaches the prompt.
      expect(client.sent.first[1].text, isNot(contains(myTeamNote!)));
    });

    test("a provider that is not configured is named", () async {
      final backend = backendOver([]);
      final events = await send(backend, "hi", provider: "ghost");

      expect(events.whereType<ErrorEvent>().single.message, contains("'ghost' is not configured"));
    });

    test("a provider that names a default does not need it pinned", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi", model: null);

      expect(client.calls.single.model, "fake-model");
    });

    test("a provider whose models are listed but default unnamed cannot be guessed at", () async {
      providers = const [
        LlmProviderConfig(
            id: "fake",
            api: LlmApi.openai,
            baseUrl: "https://example.test/v1",
            models: ["fake-model"]),
      ];
      final backend = backendOver([]);
      final events = await send(backend, "hi", model: null);

      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });

    test("the turn runs in the chat's own workspace", () async {
      final backend = backendOver([
        [bashCall("pwd")],
        [finish],
      ]);
      await send(backend, "where am I?");

      expect(Directory(config.workspaceDir(chatId)).existsSync(), isTrue);
      expect(client.sent.first[1].text, contains(config.workspaceDir(chatId)));
    });

    test("the model is told about the project workspace it shares", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi");

      expect(Directory(config.projectWorkspaceDir()).existsSync(), isTrue);
      expect(client.sent.first[1].text, contains(config.projectWorkspaceDir()));
    });

    test("workspace instructions are loaded and sent", () async {
      final backend = backendOver([
        [finish],
      ]);
      // The chat workspace is created by the turn; the project workspace is
      // where the AGENTS.md the loader should find lives.
      Directory(config.projectWorkspaceDir()).createSync(recursive: true);
      File(p.join(config.projectWorkspaceDir(), "AGENTS.md"))
          .writeAsStringSync("project rules");

      await send(backend, "hi");

      expect(client.sent.first[1].text, contains("project rules"));
      expect(client.sent.first[1].text, contains("Workspace instructions"));
    });

    test("a bundled note stands in for the files, and the files are not read",
        () async {
      final backend = backendOver([
        [finish],
      ]);
      Directory(config.projectWorkspaceDir()).createSync(recursive: true);
      File(p.join(config.projectWorkspaceDir(), "AGENTS.md"))
          .writeAsStringSync("project rules");
      File(config.globalInstructionsFile).writeAsStringSync("global rules");

      await send(backend, "hi",
          project: "anonymous",
          sharedWorkspace: false,
          bundledInstructions: "This is an anonymous chat.",
          includesUserInstructions: false);

      final system = client.sent.first[1].text;
      expect(system, contains("This is an anonymous chat."));
      expect(system, isNot(contains("project rules")));
      expect(system, isNot(contains("global rules")));
    });

    test("a bundled note that includes the user's instructions reads the "
        "files after it, so the user's rules win on conflict", () async {
      final backend = backendOver([
        [finish],
      ]);
      Directory(config.projectWorkspaceDir(project: "byte-repair"))
          .createSync(recursive: true);
      File(p.join(config.projectWorkspaceDir(project: "byte-repair"),
          "AGENTS.md"))
          .writeAsStringSync("project rules");
      File(config.globalInstructionsFile).writeAsStringSync("global rules");

      await send(backend, "hi",
          project: "byte-repair",
          bundledInstructions: "This is a Byte Repair project.",
          includesUserInstructions: true);

      final system = client.sent.first[1].text;
      // The bundled note is the base.
      expect(system, contains("This is a Byte Repair project."));
      // The user's files are read on top of it, global then project.
      expect(system, contains("global rules"));
      expect(system, contains("project rules"));
      // The note renders before the files — the project file wins on conflict
      // because it is rendered last, the way it is for a user's project.
      expect(system.indexOf("This is a Byte Repair project."),
          lessThan(system.indexOf("project rules")));
    });

    group("recording the first instruction read", () {
      InstructionRef ref(String path, InstructionKind kind) =>
          InstructionRef(path: path, kind: kind);

      /// The reply whose parts record [first]'s read events and say "done" —
      /// the shape a turn's own log entry takes, which is what the next
      /// turn's history holds.
      Message replyRecording(List<AgentEvent> first) => Message(
            id: "reply-1",
            role: MessageRole.assistant,
            createdAt: sentAt,
            parts: [
              for (final read in first.whereType<InstructionsReadEvent>())
                MessagePart.instructions(files: read.files),
              const MessagePart.text(text: "done", responseId: "r1"),
            ],
          );

      /// The shape `instructions_test.dart` builds, on this config's layout:
      /// the global file at the data dir's root and the project's at its
      /// workspace root.
      void writeInstructions({bool importsIntoProject = false}) {
        File(config.globalInstructionsFile)
            .writeAsStringSync(importsIntoProject ? "see @./notes.md" : "global rules");
        if (importsIntoProject) {
          File(p.join(config.projectWorkspaceDir(), "notes.md"))
              .writeAsStringSync("the notes");
        }
        File(config.projectInstructionsFile())
            .writeAsStringSync(importsIntoProject ? "see @./notes.md" : "project rules");
      }

      test("the first turn records every file it reads, before the response",
          () async {
        final backend = backendOver([
          [finish],
        ]);
        writeInstructions();

        final events = await send(backend, "hi");

        final reads = events.whereType<InstructionsReadEvent>().toList();
        expect(reads, hasLength(1));
        expect(reads.single.files,
            [ref(config.globalInstructionsFile, InstructionKind.global),
             ref(p.join(config.projectWorkspaceDir(), "AGENTS.md"),
                 InstructionKind.project)]);
        // The read precedes the first response: the part is the reply's first,
        // and the label renders above the thinking one.
        expect(events.indexOf(reads.single), lessThan(
            events.indexOf(events.whereType<ResponseStart>().first)));
      });

      test("a later turn re-reading the same files records nothing", () async {
        final backend = backendOver([
          [finish],
          [finish],
        ]);
        writeInstructions();

        final first = await send(backend, "hi");
        final events = await send(backend, "again",
            history: [userMessage("hi", at: sentAt), replyRecording(first)]);

        expect(events.whereType<InstructionsReadEvent>(), isEmpty);
        // The files are still in front of the model: recorded once, read
        // every turn as ever.
        expect(client.sent.last[1].text, contains("project rules"));
      });

      test("an import added between turns is the only thing recorded", () async {
        final backend = backendOver([
          [finish],
          [finish],
        ]);
        writeInstructions();

        final first = await send(backend, "hi");
        // Between turns, the project file gains an import pointing at a new
        // file, the way a user editing it between turns reaches the next one.
        File(p.join(config.projectWorkspaceDir(), "AGENTS.md"))
            .writeAsStringSync("project rules\nsee @./notes.md");
        File(p.join(config.projectWorkspaceDir(), "notes.md"))
            .writeAsStringSync("the notes");

        final events = await send(backend, "again",
            history: [userMessage("hi", at: sentAt), replyRecording(first)],
            memory: MemorySettings(imports: true));

        final reads = events.whereType<InstructionsReadEvent>().toList();
        expect(reads, hasLength(1));
        expect(reads.single.files,
            [ref(p.join(config.projectWorkspaceDir(), "notes.md"),
                InstructionKind.imported)]);
      });

      test("a read that pulls a nested AGENTS.md in records it, and the "
          "rendered block still reaches the model", () async {
        final backend = backendOver([
          [readCall("sub/notes.txt")],
          [finish],
        ]);
        writeInstructions();
        // The chat's own workspace is where the file the model reads sits, and
        // `sub/` above it is where its AGENTS.md was reached through.
        final sub = p.join(config.workspaceDir(chatId), "sub");
        Directory(sub).createSync(recursive: true);
        File(p.join(sub, "AGENTS.md")).writeAsStringSync("sub rules");
        File(p.join(sub, "notes.txt")).writeAsStringSync("the contents");

        final events = await send(backend, "read it");

        final nested = events
            .whereType<InstructionsReadEvent>()
            .skip(1)
            .toList();
        expect(nested, hasLength(1));
        expect(nested.single.files,
            [ref(p.join(sub, "AGENTS.md"), InstructionKind.directory)]);
        // The block rides the result, which is the only route nested
        // instructions reach the model by — the read's own numbered lines
        // first, then the rendered instructions.
        final result =
            events.whereType<ToolResultEvent>().first.result;
        expect(result.output, "1: the contents\n"
            "\n\n"
            "${renderInstructions([
              InstructionFile(
                  path: p.join(sub, "AGENTS.md"),
                  kind: InstructionKind.directory,
                  content: "sub rules")
            ])}");
      });

      test("reading the same nested file again in a later turn records "
          "nothing", () async {
        final backend = backendOver([
          [readCall("sub/notes.txt")],
          [finish],
          [readCall("sub/notes.txt")],
          [finish],
        ]);
        writeInstructions();
        final sub = p.join(config.workspaceDir(chatId), "sub");
        Directory(sub).createSync(recursive: true);
        File(p.join(sub, "AGENTS.md")).writeAsStringSync("sub rules");
        File(p.join(sub, "notes.txt")).writeAsStringSync("the contents");

        final first = await send(backend, "read it");
        final events = await send(backend, "again",
            history: [userMessage("hi", at: sentAt), replyRecording(first)]);

        expect(events.whereType<InstructionsReadEvent>(),
            isEmpty);
      });

      test("a rewind takes the record back, so re-running records again",
          () async {
        final backend = backendOver([
          [finish],
          [finish],
        ]);
        writeInstructions();

        await send(backend, "hi");
        // The history of the rewound conversation: the prompt and a reply
        // that never carried the part, which is what a rewind past it leaves.
        final events = await send(backend, "again",
            history: [
              userMessage("hi", at: sentAt),
              replyRecording(const []),
            ]);

        final reads = events.whereType<InstructionsReadEvent>().toList();
        expect(reads, hasLength(1));
        expect(reads.single.files, hasLength(2));
      });

      test("a retry round re-running the load is not recorded twice", () async {
        // The first attempt fails the request; the turn's automatic retry
        // (the controller's half — here the caller drives it) re-enters
        // `resumeTurn` over a history holding the first round's part, so the
        // second send's claim set already names every file.
        final backend = backendOver([
          [finish],
          [finish],
        ]);
        client.failures[0] = const LlmException("blip", retryable: true);
        writeInstructions();

        final first = await send(backend, "hi");
        expect(first.whereType<InstructionsReadEvent>(), hasLength(1));

        final events = await resuming(backend, [
          userMessage("hi", at: sentAt),
          replyRecording(first),
        ]);

        expect(events.whereType<InstructionsReadEvent>(), isEmpty);
      });

      test("a ! command records nothing", () async {
        final bypass = backendOver([], respond: (_) => ok(""));
        writeInstructions();
        Directory(config.workspaceDir(chatId)).createSync(recursive: true);

        final events = await send(bypass, "!pwd");

        expect(events.whereType<InstructionsReadEvent>(), isEmpty);
        expect(events.whereType<ShellRunEvent>(), hasLength(1));
      });

      test("a bundled note without the user's files records nothing", () async {
        final backend = backendOver([
          [finish],
        ]);
        writeInstructions();

        final events = await send(backend, "hi",
            project: "anonymous",
            sharedWorkspace: false,
            bundledInstructions: "This is an anonymous chat.",
            includesUserInstructions: false);

        expect(events.whereType<InstructionsReadEvent>(), isEmpty);
      });

      test("a bundled note that includes the user's files records them",
          () async {
        final backend = backendOver([
          [finish],
        ]);
        Directory(config.projectWorkspaceDir(project: "byte-repair"))
            .createSync(recursive: true);
        File(p.join(config.projectWorkspaceDir(project: "byte-repair"),
            "AGENTS.md")).writeAsStringSync("project rules");
        File(config.globalInstructionsFile).writeAsStringSync("global rules");

        final events = await send(backend, "hi",
            project: "byte-repair",
            bundledInstructions: "This is a Byte Repair project.",
            includesUserInstructions: true);

        final reads = events.whereType<InstructionsReadEvent>().toList();
        expect(reads, hasLength(1));
        expect(reads.single.files, hasLength(2));
        // The bundled note itself is not a file read, so it is not in the
        // record.
        expect(reads.single.files.where((f) => f.kind == InstructionKind.bundled),
            isEmpty);
      });
    });

    test("relevant memories are recalled into the turn", () async {
      final backend = backendOver([
        [finish],
      ]);
      final store = MemoryStore(config.fs, config.memoryDir());
      await store.add("the user likes code formatted with tabs");
      await store.add("notes about the weather");

      await send(backend, "how should the code be formatted",
          memory: MemorySettings(
              autoMemory: true, memoryDir: config.memoryDir()));

      final system = client.sent.first[1].text;
      expect(system, contains("Recalled memories"));
      expect(system, contains("the user likes code formatted with tabs"));
      // The other memory shares only a word the recalled one has too, which
      // is not specific enough: it is on the index's line, nowhere else — the
      // recall did not over-fetch it.
      expect(system.split("notes about the weather").length - 1, 1);
    });

    test("no recall section when the recall gate is off", () async {
      final backend = backendOver([
        [finish],
      ]);
      final store = MemoryStore(config.fs, config.memoryDir());
      await store.add("the user likes code formatted with tabs");

      await send(backend, "how should the code be formatted",
          memory: MemorySettings(
              autoMemory: true, recall: false, memoryDir: config.memoryDir()));

      expect(client.sent.first[1].text, isNot(contains("Recalled memories")));
    });

    test("an empty store recalls nothing and the turn still runs", () async {
      final backend = backendOver([
        [finish],
      ]);

      final events = await send(backend, "how should the code be formatted",
          memory: MemorySettings(
              autoMemory: true, memoryDir: config.memoryDir()));

      expect(client.sent.first[1].text, isNot(contains("Recalled memories")));
      expect(events.last, isA<DoneEvent>());
    });

    test("pinned memories reach the turn in full, the rest as an index",
        () async {
      final backend = backendOver([
        [finish],
      ]);
      final store = MemoryStore(config.fs, config.memoryDir());
      await store.add("the user likes code formatted with tabs");
      await store.add("the codebase is called Entoli");
      final standing = await store.add("the deploy key rotates every month");
      await store.pin(standing.id);

      await send(backend, "unrelated question",
          memory: MemorySettings(
              autoMemory: true, memoryDir: config.memoryDir()));

      final system = client.sent.first[1].text;
      expect(system, contains("Pinned memories"));
      expect(system, contains("the deploy key rotates every month"));
      expect(system, contains("Memory index"));
      expect(system, contains("the user likes code formatted with tabs"));
      expect(system, contains("the codebase is called Entoli"));
      // The pinned one is in the block, not in the index: one place for it.
      expect(system.split("the deploy key rotates every month").length - 1, 1);
    });

    test("no pinned or index section while the recall gate is off",
        () async {
      final backend = backendOver([
        [finish],
      ]);
      final store = MemoryStore(config.fs, config.memoryDir());
      final standing = await store.add("the deploy key rotates every month");
      await store.pin(standing.id);

      await send(backend, "unrelated question",
          memory: MemorySettings(
              autoMemory: true, recall: false, memoryDir: config.memoryDir()));

      final system = client.sent.first[1].text;
      expect(system, isNot(contains("Pinned memories")));
      expect(system, isNot(contains("Memory index")));
    });

    test("a chat in a project works in that project's directories", () async {
      final backend = backendOver([
        [finish],
      ]);
      await backend
          .sendPrompt(chatId, userMessage("hi", at: sentAt),
              settings: const TurnSettings(
                  model: "fake-model",
                  provider: "fake",
                  project: "work",
                  approveMode: ApproveMode.never))
          .toList();

      final system = client.sent.first[1].text;
      expect(system, contains(config.workspaceDir(chatId, project: "work")));
      expect(system, contains(config.projectWorkspaceDir(project: "work")));
      expect(Directory(config.projectWorkspaceDir(project: "work")).existsSync(), isTrue);
    });

    // Scratch work a later turn may want is the workspace's, not the machine
    // temp directory's — /tmp was where the crops that a chat lost came from.
    test("the workspace prompt keeps work in the chat until the user moves it",
        () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi");

      final system = client.sent.first[1].text;
      expect(system, contains("Everything you make in this conversation goes here."));
      expect(system, contains("Move work there only when the user wants"));
      // /tmp is mapped to the chat's own scratch, so nothing steers away from it.
      expect(system, isNot(contains("machine's /tmp")));
    });

    // A project that does not share a workspace is the answer to "a chat that
    // must not reach past itself": the prompt names the chat's own workspace
    // and nothing of a shared one.
    test("a turn with no shared workspace is told nothing of one", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi", project: "anonymous", sharedWorkspace: false);

      final workspace = config.workspaceDir(chatId, project: "anonymous");
      final system = client.sent.first[1].text;
      // The chat's own workspace is named...
      expect(system, contains(workspace));
      // ...and the shared project workspace is not.
      expect(system, isNot(contains("shared with every other")));
    });

    // A project's takeaways are the same machinery a headless turn uses to drop
    // `ask` and `task`: one value, so the prompt and the tool list cannot
    // disagree. A capability a project takes away is not named in the prompt.
    test("a disabled capability is not named in the prompt", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi", disabled: {AgentCapability.task});

      final system = client.sent.first[0].text;
      expect(system, isNot(contains("to delegate a task to a sub-agent")));
    });
  });

  group("commands and agents", () {
    PromptLibrary libraryWith(CompletionKind kind, String name, String body) =>
        PromptLibrary([PromptDocument.parse(kind, name, "---\ndescription: d\n---\n\n$body")]);

    test("/name expands to the command's template", () async {
      final asWritten =
          libraryWith(CompletionKind.skill, "review", "Review this:\n\n\$ARGUMENTS");
      final backend = backendOver([
        [finish],
      ], library: asWritten);
      await send(backend, "/review the parser",
          documents: promptDocuments("/review the parser", asWritten));

      expect(client.sent.first[2].text, contains("Review this:\n\nthe parser"));
      expect(client.sent.first[2].text, isNot(contains(r"$ARGUMENTS")));
    });

    test("a command with no placeholder gets its arguments appended", () async {
      final asWritten =
          libraryWith(CompletionKind.skill, "commit", "Commit what changed.");
      final backend = backendOver([
        [finish],
      ], library: asWritten);
      await send(backend, "/commit only the tests",
          documents: promptDocuments("/commit only the tests", asWritten));

      expect(client.sent.first[2].text, contains("Commit what changed."));
      expect(client.sent.first[2].text, contains("only the tests"));
    });

    test("a name the library does not know is left as the prose it probably is", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.skill, "review", "Review this."),
      );
      await send(backend, "/etc/hosts is where?");

      expect(client.sent.first[2].text, contains("/etc/hosts is where?"));
    });

    test("@name puts that agent's prompt under the system message", () async {
      final asWritten =
          libraryWith(CompletionKind.agent, "researcher", "You only read.");
      final backend = backendOver([
        [finish],
      ], library: asWritten);
      await send(backend, "@researcher where is the parser?",
          documents: promptDocuments("@researcher where is the parser?", asWritten));

      expect(client.sent.first[1].text, contains("You only read."));
      expect(client.sent.first[2].text, contains("@researcher where is the parser?"));
    });

    test("a command edited since is still the words the turn was sent with",
        () async {
      final asWritten = libraryWith(CompletionKind.skill, "review", "Look hard at:\n\n\$ARGUMENTS");
      final backend = backendOver(
        [
          [finish],
        ],
        // The library the turn is replayed against says something else
        // entirely, and a deleted command would say nothing at all.
        library: libraryWith(CompletionKind.skill, "review", "REWRITTEN"),
      );
      await send(backend, "/review the parser",
          documents: promptDocuments("/review the parser", asWritten));

      expect(client.sent.first[2].text, contains("Look hard at:\n\nthe parser"));
      expect(client.sent.first[2].text, isNot(contains("REWRITTEN")));
    });

    test("a command deleted since still reads back", () async {
      final asWritten = libraryWith(CompletionKind.skill, "review", "Review this.");
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "/review the parser",
          documents: promptDocuments("/review the parser", asWritten));

      expect(client.sent.first[2].text, contains("Review this."));
    });

    test("an agent edited since carries on under what the turn ran under",
        () async {
      final asWritten = libraryWith(CompletionKind.agent, "researcher", "You only read.");
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.agent, "researcher", "REWRITTEN"),
      );
      // Resumed rather than sent: the `@agent` is read off the message that
      // started the turn, which is where its record is.
      await resuming(backend, [
        userMessage("@researcher where is the parser?",
            at: sentAt,
            documents: promptDocuments("@researcher where is the parser?", asWritten)),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "part way", responseId: "r1")],
        ),
      ]);

      expect(client.sent.first[1].text, contains("You only read."));
      expect(client.sent.first[1].text, isNot(contains("REWRITTEN")));
    });

    test("an email address is not a mention", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.agent, "example", "You only read."),
      );
      await send(backend, "write to me@example.com");

      expect(client.sent.first.map((m) => m.text).join(),
          isNot(contains("You only read.")));
    });
  });

  group("running a command yourself", () {
    test("a ! message runs the command and never reaches a model", () async {
      final backend = backendOver([], respond: (c) =>
          c.startsWith("cat")
              ? const ShellResult(returnCode: 2, output: "no such file")
              : ok("hello\n"));
      final events = await send(backend, "!echo hello");

      expect(shell.ran, ["echo hello"]);
      expect(client.sent, isEmpty);
      final run = events.whereType<ShellRunEvent>().single.run;
      expect((run.command, run.returnCode, run.output), ("echo hello", 0, "hello\n"));
      // What it exited with comes back with it, whatever the code.
      final failing = await send(backend, "!cat nothing");
      expect(failing.whereType<ShellRunEvent>().single.run.returnCode, 2);
      expect(events.last, isA<DoneEvent>());
    });

    test("the command is what follows the bang, with the space gone", () async {
      final backend = backendOver([], respond: (_) => ok(""));
      await send(backend, "!  ls -la  ");

      expect(shell.ran, ["ls -la"]);
    });

    test("a bang anywhere but the front is prose", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "what does !! do?");

      expect(shell.ran, isEmpty);
      expect(client.sent, hasLength(1));
    });

    // The point of running the command yourself: it is not a model's to
    // approve or to be configured for.
    test("nothing is asked about, since the user typed it themselves", () async {
      final backend = backendOver([], respond: (_) => ok(""));
      final events = await asking(backend, "!rm -rf build").toList();

      expect(shell.ran, ["rm -rf build"]);
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("a chat with no provider can still run one", () async {
      final backend = backendOver([], respond: (_) => ok("out"));
      final events = await send(backend, "!ls", provider: null, model: null);

      expect(shell.ran, ["ls"]);
      expect(events.whereType<ErrorEvent>().map((e) => e.message), isEmpty);
    });

    test("it runs in the chat's own workspace, with the project's for a home",
        () async {
      final backend = backendOver([], respond: (_) => ok(""));
      await send(backend, "!pwd");

      expect(shell.cwds, [config.workspaceDir(chatId)]);
      expect(shell.homes, [config.projectWorkspaceDir()]);
      expect(Directory(config.workspaceDir(chatId)).existsSync(), isTrue);

      // Where no workspace is shared, the chat's own is the home too.
      await send(backend, "!pwd", project: "anonymous", sharedWorkspace: false);
      final workspace = config.workspaceDir(chatId, project: "anonymous");
      expect(shell.cwds.last, workspace);
      expect(shell.homes.last, workspace);
    });

    test("stopping the turn kills the command", () async {
      final backend = backendOver([]);
      shell.hang.add("sleep 100");

      final turn = asking(backend, "!sleep 100").toList();
      await pumpEvents();
      await backend.abort(chatId);
      await turn.timeout(const Duration(seconds: 5));

      expect(shell.killed, ["sleep 100"]);
    });

    test("stopping the turn keeps what the command printed", () async {
      final backend = backendOver([]);
      shell.hang.add("sleep 100");
      shell.killedOutput = "hello\n";

      final turn = asking(backend, "!sleep 100").toList();
      await pumpEvents();
      await backend.abort(chatId);
      final events = await turn.timeout(const Duration(seconds: 5));

      expect(events.whereType<ShellRunEvent>().single.run.output, "hello\n");
      expect(events.whereType<DoneEvent>().single.aborted, isTrue);
    });

    test("stopping an agent's command keeps what it printed", () async {
      final backend = backendOver([
        [bashCall("sleep 100")],
      ]);
      shell.hang.add("sleep 100");
      shell.killedOutput = "hello\n";

      final turn =
          asking(backend, "hi", approveMode: ApproveMode.never).toList();
      await untilPending("the command", () async =>
          shell.ran.contains("sleep 100") ? const [true] : const <bool>[]);
      await backend.abort(chatId);
      final events = await turn.timeout(const Duration(seconds: 5));

      expect(events.whereType<ToolResultEvent>().single.result.output,
          contains("hello"));
      expect(events.whereType<DoneEvent>().single.aborted, isTrue);
    });

    test("the next turn's model is told what ran and how it ended", () async {
      final backend = backendOver([
        [finish],
      ], respond: (_) => ok("hello\n"));
      await send(backend, "!echo hello");
      await send(backend, "what did that say?");

      final sent = client.sent.single.map((m) => m.text).join("\n");
      expect(sent, contains("echo hello"));
      expect(sent, contains('"returncode": 0'));
    });

    test("an ordinary chat carried on after a restart is the one that was left",
        () async {
      // The same invariant the `!` turn below keeps, for the path every other
      // turn takes. It is what the on-device KV cache rests on: a chat reopened
      // or regenerated has to send the text that was sent before, or every
      // cached prefix past the system prompt misses and the whole history is
      // read again. See "The projection" in `lib/domain/AGENTS.md`.
      final live = backendOver([
        [finish],
        [finish],
      ]);
      await send(live, "first");
      await send(live, "second");
      final held = client.sent.last.map((m) => (m.role, m.text)).toList();

      final restarted = backendOver([
        [finish],
      ]);
      await send(restarted, "second", history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "first")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "done", responseId: "r1")],
        ),
      ]);

      expect(client.sent.single.map((m) => (m.role, m.text)), held);
    });

    // A tool's outcome was worded twice — once as the turn ran, once out of the
    // log — and for the file tools the two said different things, so every chat
    // that had read or edited anything diverged the moment it was reopened.
    test("a tool result reads the same live as it does after a restart", () async {
      final live = backendOver([
        [fileCall("read", {"path": "notes.txt"})],
        [finish],
      ]);
      await send(live, "what is in notes.txt?");
      final answered = client.sent.last.singleWhere((m) => m.role == LlmRole.tool);

      final restarted = backendOver([
        [finish],
      ]);
      await send(restarted, "and now?", history: [
        userMessage("what is in notes.txt?", at: sentAt),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [
            MessagePart.toolCall(
                toolCall: ToolCall(
                    id: "file-1", name: "read", argumentsJson: '{"path":"notes.txt"}'),
                responseId: "r1"),
            MessagePart.toolResult(
                result: ToolResult(
                    callId: "file-1",
                    returnCode: -1,
                    output: "",
                    exceptionInfo: "File not found: notes.txt")),
          ],
        ),
      ]);
      final rebuilt = client.sent.last.singleWhere((m) => m.role == LlmRole.tool);

      expect(answered.text, contains("File not found: notes.txt"));
      expect(rebuilt.text, answered.text);
    });

    // The live session is filled as the command finishes and a reload builds
    // the same exchange back out of the log. Attached, because what is named to
    // the model is the half a hand-written session line would get wrong.
    test("a chat carried on after a restart is the one that was left", () async {
      final live = backendOver([
        [finish],
      ], respond: (_) => ok("hello\n"));
      await send(live, "!echo hello", files: const [
        MessagePart.file(
            resource: "r1", filename: "notes.txt", mimeType: "text/plain"),
      ]);
      await send(live, "what did that say?");
      final held = client.sent.single.map((m) => (m.role, m.text)).toList();

      final restarted = backendOver([
        [finish],
      ], respond: (_) => ok("hello\n"));
      await send(restarted, "what did that say?", history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [
            MessagePart.file(
                resource: "r1", filename: "notes.txt", mimeType: "text/plain"),
            MessagePart.text(text: "!echo hello"),
          ],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [
            MessagePart.shellRun(command: "echo hello", returnCode: 0, output: "hello\n"),
          ],
        ),
      ]);

      expect(client.sent.single.map((m) => (m.role, m.text)), held);
      expect(held.map((m) => m.$2).join("\n"), contains("notes.txt"));
    });
  });

  group("approvals", () {
    test("a pending one is offered until it is answered", () async {
      final backend = backendOver([
        [bashCall("rm -rf build")],
        [finish],
      ]);

      final events = <AgentEvent>[];
      final turn = asking(backend, "clean").forEach(events.add);

      // The banner's arrival is the turn's own async hop; polled, not beaten.
      final pending = await untilPending(
          "the approval", () => backend.pendingApprovals(chatId));
      expect(pending.single.toolName, "bash");
      expect(pending.single.argumentsJson, contains("rm -rf build"));

      await backend.respondApproval(chatId, pending.single.id, ApprovalResponse.allow);
      await turn;

      expect(shell.ran, contains("rm -rf build"));
      expect(await backend.pendingApprovals(chatId), isEmpty);
    });

    test("denying it stops the command without stopping the turn", () async {
      final backend = backendOver([
        [bashCall("rm -rf /")],
        [finish],
      ]);

      final turn = asking(backend, "clean").toList();
      final first = (await untilPending(
          "the approval", () => backend.pendingApprovals(chatId))).single;
      await backend.respondApproval(chatId, first.id, ApprovalResponse.deny);
      final events = await turn;

      expect(shell.ran, isNot(contains("rm -rf /")));
      expect(events.last, isA<DoneEvent>());
    });

    test("an answer that beats the agent to it is not lost", () async {
      final backend = backendOver([
        [bashCall("ls")],
        [finish],
      ]);

      // The banner is on screen the moment the event is forwarded, which is a
      // turn of the loop before the agent gets round to waiting on it.
      await asking(backend, "list").listen((event) {
        if (event is ApprovalRequestEvent) {
          backend.respondApproval(chatId, event.approval.id, ApprovalResponse.allow);
        }
      }).asFuture<void>();

      expect(shell.ran, ["ls"]);
    });

    test("aborting answers what was still on screen, so nothing is left waiting", () async {
      final backend = backendOver([
        [bashCall("rm -rf build")],
      ]);

      final turn = asking(backend, "clean").toList();
      expect(
        await untilPending(
            "The approval", () async => await backend.pendingApprovals(chatId)),
        hasLength(1),
      );

      await backend.abort(chatId);
      await turn.timeout(const Duration(seconds: 5));

      expect(shell.ran, isEmpty);
      expect(await backend.pendingApprovals(chatId), isEmpty);
    });
  });

  group("questions", () {
    final askWhich = askCall({
      "questions": [
        {
          "question": "Which database?",
          "options": [
            {"label": "Postgres"},
            {"label": "SQLite"},
          ],
        },
      ],
    });

    test("one is offered until it is answered, and the answer reaches the model",
        () async {
      final backend = backendOver([
        [askWhich],
        [finish],
      ]);

      final turn = asking(backend, "set up storage", approveMode: ApproveMode.never).toList();

      final pending =
          (await untilPending("The question", () => backend.pendingQuestions(chatId)))
              .single;
      expect(pending.questions.single.question, "Which database?");

      await backend.respondQuestions(chatId, pending.id, ["Postgres"]);
      await turn;

      expect(backend.pendingQuestions(chatId), isEmpty);
      expect(client.sent[1].firstWhere((m) => m.toolCallId == pending.id).text,
          contains("Postgres"));
    });

    test("an answer that beats the agent to it is not lost", () async {
      final backend = backendOver([
        [askWhich],
        [finish],
      ]);

      await asking(backend, "set up storage", approveMode: ApproveMode.never).listen((event) {
        if (event is QuestionRequestEvent) {
          backend.respondQuestions(chatId, event.request.id, ["SQLite"]);
        }
      }).asFuture<void>();

      expect(client.sent[1].map((m) => m.text).join(), contains("SQLite"));
    });

    test("aborting answers what was on screen, so nothing is left waiting", () async {
      final backend = backendOver([
        [askWhich],
      ]);

      final turn = asking(backend, "set up storage", approveMode: ApproveMode.never).toList();
      await untilPending("The question", () => backend.pendingQuestions(chatId));

      await backend.abort(chatId);
      await turn.timeout(const Duration(seconds: 5));

      expect(backend.pendingQuestions(chatId), isEmpty);
    });
  });

  group("which turns are running", () {
    test("a chat is listed for the whole of its turn", () async {
      final backend = backendOver([
        [finish],
      ]);
      final seen = <Set<String>>[];
      backend.runningTurns.addListener(() => seen.add(backend.runningTurns.value));

      var listedAtTheEnd = false;
      await for (final event in backend.sendPrompt(chatId, userMessage("hi", at: sentAt),
          settings: const TurnSettings(
              model: "fake-model", provider: "fake", approveMode: ApproveMode.never))) {
        // The listener writing the turn's closing records is still reading this
        // stream, so the hold has to outlast the last event rather than the
        // agent that produced it.
        if (event is DoneEvent) listedAtTheEnd = backend.runningTurns.value.contains(chatId);
      }

      expect(listedAtTheEnd, isTrue);
      // Only now: the drop is deliberately after the stream closes, so it lands
      // a microtask behind the reader that has just finished with it.
      await pumpEvents();
      expect(seen, [
        {chatId},
        <String>{},
      ]);
    });

    test("aborting says so on the way out, so the turn is not logged as done",
        () async {
      final backend = backendOver([
        [bashCall("sleep 5")],
      ]);
      final events = <AgentEvent>[];
      final turn = asking(backend, "hi", approveMode: ApproveMode.ask).listen(events.add);
      await pumpEvents();

      await backend.abort(chatId);
      await turn.cancel();

      expect(events.whereType<DoneEvent>().single.aborted, isTrue);
      expect(backend.runningTurns.value, isEmpty);
    });

    test("aborting a parallel round ends every turn's stream", () async {
      final backend = backendOver([
        [bashCall("rm -rf a")],
        [bashCall("rm -rf b")],
      ]);
      final first = asking(backend, "one").toList();
      final second = asking(backend, "two").toList();
      await untilPending("Both approvals", () async {
        final pending = await backend.pendingApprovals(chatId);
        return pending.length == 2 ? pending : const <ToolApproval>[];
      });

      await backend.abort(chatId);
      final ended = await Future.wait([first, second])
          .timeout(const Duration(seconds: 5));

      for (final events in ended) {
        expect(events.whereType<DoneEvent>().last.aborted, isTrue);
      }
      expect(backend.openTurnStreams, 0);
    });

    test("a finished turn drops its stream", () async {
      final backend = backendOver([
        [finish],
      ]);
      await asking(backend, "hi", approveMode: ApproveMode.never).toList();
      await pumpEvents();

      expect(backend.openTurnStreams, 0);
    });

    test("a chat with nothing running is not published again", () async {
      final backend = backendOver([]);
      var notified = 0;
      backend.runningTurns.addListener(() => notified++);

      await backend.abort("never-ran");

      expect(notified, 0);
    });
  });

  group("carrying on a killed sub-agent", () {
    /// A conversation stopped mid-fan-out: the reply holds a `task` call whose
    /// result never landed, which is what a killed turn leaves behind.
    List<Message> historyWithPendingTask({String callId = "task-1"}) => [
          Message(
            id: "u1",
            role: MessageRole.user,
            createdAt: DateTime.utc(2026),
            parts: [MessagePart.text(text: "count the files")],
          ),
          Message(
            id: "a1",
            role: MessageRole.assistant,
            createdAt: DateTime.utc(2026),
            parts: [
              MessagePart.toolCall(
                toolCall: ToolCall(
                  id: callId,
                  name: "task",
                  argumentsJson: jsonEncode({"agent": "general", "prompt": "count"}),
                ),
              ),
            ],
          ),
        ];

    /// The transcript that sub-agent left: something said, and no `turnEnd`.
    Future<void> seedKilledSubAgent(String callId, String said) =>
        FileSubAgentLog(config, chatId).append(
            callId,
            recordsOf([
              Message(
                id: callId,
                role: MessageRole.assistant,
                createdAt: DateTime.utc(2026),
                parts: [MessagePart.text(text: said)],
              ),
            ]));

    test("it is carried on, and its answer reaches the parent", () async {
      await seedKilledSubAgent("task-1", "I was halfway through");
      // The sub-agent finishes, then the parent says its piece.
      final backend = backendOver([
        [saidOnly("there are three")],
        [finish],
      ]);

      final events = await resuming(backend, historyWithPendingTask());

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "task-1")
          .result;
      expect(result.returnCode, 0);
      expect(result.output, contains("there are three"));
      // The parent is shown the answer, not that it was interrupted: the
      // sub-agent's own output is what answers its `task` call.
      final answered = client.sent.last
          .where((m) => m.role == LlmRole.tool && m.toolCallId == "task-1");
      expect(answered.single.text, contains("there are three"));
      expect(answered.single.text, isNot(contains("interrupted")));
    });

    test("what it had already done is put back in front of it", () async {
      await seedKilledSubAgent("task-1", "I was halfway through");
      final backend = backendOver([
        [saidOnly("there are three")],
        [finish],
      ]);

      await resuming(backend, historyWithPendingTask());

      expect(client.sent.first.any((m) => m.text.contains("I was halfway through")), isTrue);
    });

    test("a call that never started keeps the interrupted wording", () async {
      // No transcript seeded: the sub-agent died before writing anything.
      final backend = backendOver([
        [finish],
      ]);

      final events = await resuming(backend, historyWithPendingTask());

      expect(events.whereType<ToolResultEvent>(), isEmpty);
      final answered = client.sent.single
          .where((m) => m.role == LlmRole.tool && m.toolCallId == "task-1");
      expect(answered.single.text, contains("interrupted"));
    });
  });

  group("sessions", () {
    // Stopped while auto mode's classifier was still answering, the old turn
    // used to wake when it did: run the command, and write itself into the
    // session the resent turn had rebuilt — a RangeError on its next step.
    test("a turn stopped mid-classification stops there", () async {
      final verdict = Completer<void>();
      final judge = FakeLlmClient([
        [const LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "allow"))],
        [const LlmCompletion(message: LlmMessage(role: LlmRole.assistant, text: "ask"))],
      ]);
      final backend = backendOver([
        [bashCall("pdflatex main.tex")],
        [bashCall("rm -rf build", id: "call-2")],
        [finish],
      ], judge: _Held(judge, verdict.future));
      Stream<AgentEvent> auto(String text) => backend.sendPrompt(
          chatId, userMessage(text, at: sentAt),
          settings: const TurnSettings(
              model: "fake-model",
              provider: "fake",
              classifierProvider: "judge",
              classifierModel: "judge-model",
              approveMode: ApproveMode.auto));

      final first = auto("one").toList();
      await untilPending("the classifier",
          () async => judge.sent.isEmpty ? const <bool>[] : const [true]);
      await backend.abort(chatId);
      await first;

      // The resend: the log's thread, with the stopped call unanswered.
      await backend.resetSession(chatId, history: [
        userMessage("one", at: sentAt),
        Message(
          id: "a1",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [
            MessagePart.toolCall(
                toolCall: ToolCall(
                    id: "call-1", name: "bash", argumentsJson: '{"command":"pdflatex main.tex"}')),
          ],
        ),
      ]);
      final second = auto("two").toList();
      final pending = await untilPending(
          "the approval", () => backend.pendingApprovals(chatId));
      verdict.complete();
      await pumpEvents();
      await backend.respondApproval(chatId, pending.single.id, ApprovalResponse.allow);
      final events = await second;

      expect(shell.ran, ["rm -rf build"]);
      expect(events.whereType<ErrorEvent>().map((e) => e.message), isEmpty);
      expect(client.sent.last.map((m) => m.text).join("\n"), contains("two"));
    });

    test("a second prompt continues the conversation", () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "first");
      await send(backend, "second");

      expect(client.sent.last.map((m) => m.text).join(), contains("first"));
      expect(client.sent.last.last.text, contains("second"));
    });

    test("resetting seeds the next turn with what was kept", () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "first");
      await backend.resetSession(chatId, history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "what is 2+2?")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "four")],
        ),
      ]);
      await send(backend, "and 3+3?");

      final transcript = client.sent.last.map((m) => m.text).join("\n");
      expect(transcript, contains("what is 2+2?"));
      expect(transcript, contains("four"));
      expect(transcript, isNot(contains("first")));
    });

    // Sessions live in memory, so a chat opened after a restart has none —
    // and the model would be answering the next message from nothing.
    test("a chat the backend has never held is filled from its conversation", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "and 3+3?", history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "what is 2+2?")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "four")],
        ),
      ]);

      expect(client.sent.single.map((m) => m.text).join("\n"), contains("what is 2+2?"));
    });

    test("one the backend is already holding is left alone", () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "first");
      await send(backend, "second", history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "somebody else's conversation")],
        ),
      ]);

      final transcript = client.sent.last.map((m) => m.text).join("\n");
      expect(transcript, isNot(contains("somebody else's")));
      expect(transcript, contains("first"));
    });

    // A turn that errored leaves the session behind it, so a resume that only
    // filled an empty one would hand the model those messages twice.
    test("a resume rebuilds the session even when one is already held", () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "count the files");
      await resuming(backend, [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "count the files")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [
            MessagePart.toolCall(
              toolCall: ToolCall(id: "c1", name: "bash", argumentsJson: '{"command":"ls"}'),
            ),
          ],
        ),
      ]);

      final sent = client.sent.last;
      expect(sent.where((m) => m.text.contains("count the files")), hasLength(1));
      expect(sent.last.text, contains("interrupted before it finished"));
    });

    // Why a turn is being carried on is that turn's own business, and nothing
    // logs it. A session that went on holding it would send every later turn a
    // conversation `conv.jsonl` cannot rebuild — the miss the projection exists
    // to stop, in the one place that could still cause one.
    test("the reason a turn was resumed does not outlive the turn", () async {
      final interrupted = [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "count the files")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [MessagePart.text(text: "looking", responseId: "r1")],
        ),
      ];

      final live = backendOver([
        [finish],
        [finish],
      ]);
      await resuming(live, interrupted);
      await send(live, "and now?");
      final held = client.sent.last.map((m) => (m.role, m.text)).toList();

      final restarted = backendOver([
        [finish],
      ]);
      await send(restarted, "and now?", history: [
        interrupted.first,
        interrupted.last.copyWith(parts: [
          ...interrupted.last.parts,
          const MessagePart.text(text: "done", responseId: "r2"),
        ]),
      ]);

      expect(held.map((m) => m.$2).join("\n"),
          isNot(contains("interrupted before it finished")));
      expect(client.sent.last.map((m) => (m.role, m.text)), held);
    });

    test("a rewound turn names the files it is not resending", () async {
      final backend = backendOver([
        [finish],
      ]);
      await backend.resetSession(chatId, history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: sentAt,
          parts: const [
            MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
            MessagePart.text(text: "what is this?"),
          ],
        ),
      ]);
      await send(backend, "again");

      expect(client.sent.first.map((m) => m.text).join(), contains("diagram.png"));
    });

    test("disposing a chat forgets it, and closes the shell that was running in it",
        () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "first");
      await backend.disposeChat(chatId);
      await send(backend, "second");

      expect(client.sent.last.map((m) => m.text).join(), isNot(contains("first")));
      expect(shell.closedSessions, [config.workspaceDir(chatId)]);
    });
  });

  group("the room's sessions", () {
    // The room's turns: the house answering first, then a say addressed to
    // @explore with their reply - the shape everything below syncs through.
    // The constructed messages are what a turn's settle left on the log, so a
    // reply's text is the one its script said; its id comes off the text,
    // unique inside each test, which is all a conversation needs.
    Message sayFor(String text, List<String> addressees) => Message(
            id: "m-$text",
            role: MessageRole.user,
            createdAt: sentAt,
            parts: [MessagePart.text(text: text)],
            addressees: addressees);
    Message replyBy(String text, {String? author}) => Message(
            id: "m-$text",
            role: MessageRole.assistant,
            createdAt: sentAt,
            parts: [MessagePart.text(text: text)],
            author: author);
    String transcript() => client.sent.last.map((m) => m.text).join("\n");

    test("a warm session is synced with the room's history before a turn",
        () async {
      final backend = backendOver([
        [saidOnly("done one")],
        [saidOnly("done two")],
      ]);
      final m1 = sayFor("hello", const []);
      final r1 = replyBy("done one");
      await send(backend, "hello");
      expect(client.sent, hasLength(1));

      // What the room said since: a say addressed to @explore, and their
      // reply, neither an exchange this backend ran. The house's next
      // dispatch words them into its session before the turn opens.
      final m2 = sayFor("explore the logs, @explore", const ["@explore"]);
      final r2 = replyBy("done two", author: "@explore");
      await send(backend, "thanks both",
          history: [m1, r1, m2, r2], omadaMember: null);

      expect(transcript(), contains("Message from the user, addressed to "
          "@explore (not addressed to you):\n\nexplore the logs"));
      expect(transcript(), contains("Message from explore"));
      expect(transcript(), contains("thanks both"));
      // The say that opened the chat is dressed once; the later one never.
      expect(transcript(), contains("The user asks:\n\nhello"));
      expect(transcript(), isNot(contains("The user asks:\n\nthanks both")));
    });

    test("a participant's session words what it already holds once",
        () async {
      // Three dispatches; the session's own last turn is in the next
      // dispatch's history too, and must not word twice.
      final backend = backendOver([
        [saidOnly("done one")],
        [saidOnly("done two")],
        [saidOnly("done three")],
      ]);
      final m1 = sayFor("hello", const []);
      final r1 = replyBy("done one");
      await send(backend, "hello");
      final m2 = sayFor("and how are you", const []);
      final r2 = replyBy("done two");
      await send(backend, "and how are you", history: [m1, r1]);
      await send(backend, "goodbye", history: [m1, r1, m2, r2]);

      final words = transcript();
      for (final text in [
        "hello",
        "done one",
        "and how are you",
        "done two",
        "goodbye",
      ]) {
        expect(words, contains(text));
      }
      // [system, system, m1, r1, m2, r2, and the say this turn answered].
      expect(client.sent.last, hasLength(7));
    });

    test("a member's first turn is filled from the room whole", () async {
      final backend = backendOver([
        [saidOnly("done one")],
        [saidOnly("done two")],
      ]);
      final m1 = sayFor("anyone home?", const []);
      final r1 = replyBy("done one");
      final m2 = sayFor("explore the logs, @explore", const ["@explore"]);
      final r2 = replyBy("done two", author: "@explore");
      await send(backend, "house filler", history: [m1, r1]);

      // The member's own first dispatch fills from the room whole: the say
      // it was addressed with is its mail, verbatim and dressed.
      await send(backend, "warm-up filler",
          history: [m1, r1, m2, r2], omadaMember: "explore");
      expect(transcript(), contains("The user asks:\n\nexplore the logs"));
      // The house's reply is the house's words, labeled; the house's own
      // greeting - the say above it - rides in the same wording.
      expect(transcript(), contains("Message from (main agent)"));
      expect(transcript(), contains("addressed to (main agent)"));
    });

    test("a member's warm session catches up with the room's turns", () async {
      // One member turn, then the room runs (a house exchange and another
      // member's turn), then their say: the sync words the room's turns on
      // the covered end, in log order.
      final backend = backendOver([
        [saidOnly("done one")],
        [saidOnly("done two")],
        [saidOnly("done three")],
      ]);
      final m1 = sayFor("explore the logs, @explore", const ["@explore"]);
      final r1 = replyBy("done one", author: "@explore");
      await send(backend, "explore the logs, @explore");
      expect(client.sent, hasLength(1));

      final m2 = sayFor("anyone home?", const []);
      final r2 = replyBy("done two");
      final m3 = sayFor("room talk about the diff", const ["@reviewer"]);
      final r3 = replyBy("done three", author: "@reviewer");
      await send(backend, "room filler", history: [m1, r1, m2, r2]);

      // @explore's next dispatch syncs what the room said since.
      await send(backend, "carry on, @explore",
          history: [m1, r1, m2, r2, m3, r3], omadaMember: "explore");
      expect(transcript(), contains("room talk about the diff"));
      expect(transcript(), contains("Message from (main agent)"));
      expect(transcript(), contains("Message from reviewer"));
      // And the turn's own prompt is the say, never worded twice.
      expect(transcript().split("carry on, @explore"), hasLength(2));
    });

    test("a caller whose thread diverges from the log is not trusted",
        () async {
      // The session holds an exchange this backend filled; the next dispatch
      // brings a history that words something else in the covered ids'
      // place. The sync re-words from the log itself, never from a caller's
      // copy.
      final backend = backendOver([
        [saidOnly("done one")],
      ]);
      final m1 = sayFor("explore the logs, @explore", const ["@explore"]);
      final log = replyBy("what the log actually says", author: "@explore");
      await backend.store.saveState(makeState(chatId));
      await backend.store.append(chatId, recordsOf([m1, log]));

      await send(backend, "warm-up filler",
          history: [m1, log], omadaMember: "explore");

      final bogus = sayFor("somebody else's conversation", const []);
      final bogusReply = replyBy("the fake exchange");
      await send(backend, "carry on, @explore",
          history: [bogus, bogusReply, m1, log], omadaMember: "explore");

      expect(transcript(), contains("explore the logs"));
      expect(transcript(), contains("what the log actually says"));
      expect(transcript(), contains("carry on, @explore"));
      expect(transcript(), isNot(contains("somebody else's")));
      expect(transcript(), isNot(contains("the fake exchange")));
    });

    test("a warm session's live tail confirms across a tool-calling turn",
        () async {
      // The turn before this dispatch called a tool; the session's wording of
      // it holds a tool call and an observation. The sync re-words the same
      // records per message to confirm the tail, and the two wordings must
      // agree by content: an entry that matched only by instance identity
      // would break the confirm here, leave the session's covered ids where
      // they were, and every room turn after it never worded into this
      // session at all.
      final backend = backendOver([
        [bashCall("grep logs", id: "c1")],
        [saidOnly("found ten hits")],
        [saidOnly("done two")],
        [saidOnly("done four")],
      ], respond: (_) => ok("hits\n"));

      final m1 = sayFor("grep the logs, @explore", const ["@explore"]);
      final live = Message(
          id: "m-live",
          role: MessageRole.assistant,
          createdAt: sentAt,
          parts: const [
            MessagePart.toolCall(
                toolCall: ToolCall(
                    id: "c1",
                    name: "bash",
                    argumentsJson: '{"command":"grep logs"}'),
                responseId: "r1"),
            MessagePart.toolResult(
                result: ToolResult(callId: "c1", returnCode: 0, output: "hits\n")),
            MessagePart.text(text: "found ten hits", responseId: "r2"),
          ],
          author: "@explore");
      await backend.sendPrompt(chatId, m1,
          settings: const TurnSettings(
              model: "fake-model",
              provider: "fake",
              approveMode: ApproveMode.never,
              omadaMember: "explore")).toList();

      // The room's own turn ran between, worded only into the house's
      // session — never this one's.
      final m2 = sayFor("anyone home?", const []);
      final r2 = replyBy("done two");
      await send(backend, "house filler", history: [m1, live, m2, r2],
          omadaMember: null);

      // And @explore's next dispatch words the house's exchange in; the tool
      // call's wording confirms once, and the prompt below words nothing
      // twice.
      await send(backend, "carry on, @explore",
          history: [m1, live, m2, r2], omadaMember: "explore");
      expect(transcript(), contains("anyone home?"));
      expect(transcript(), contains("Message from (main agent)"));
      // And the turn's own prompt is the say, never worded twice, whether
      // directly or inside the wording of the tool turn that confirmed it.
      expect(transcript().split("grep the logs"), hasLength(2));
    });
  });

  group("asking one question", () {
    test("is one call, with the prompt as the whole of it", () async {
      final backend = backendOver([
        [saidOnly("Sorting a list of records")],
      ]);

      final answer =
          await backend.ask("name this", model: "fake-model", provider: "fake");

      expect(answer, "Sorting a list of records");
      expect(client.sent.single, hasLength(1));
      expect(client.sent.single.single.text, "name this");
    });

    test("an ask that fails answers nothing rather than failing", () async {
      final backend = backendOver([]);

      // The provider is not one the settings know.
      expect(await backend.ask("hi", model: "m", provider: "ghost"), isNull);
      // And a request that fails mid-call answers null too.
      client.failures[0] = const LlmException("no", statusCode: 500);
      expect(await backend.ask("hi", model: "fake-model", provider: "fake"), isNull);
    });

    // The session is the conversation the agent holds; a question asked
    // outside it must not become part of it.
    test("the turn that follows has not heard of it", () async {
      final backend = backendOver([
        [saidOnly("An answer")],
        [finish],
      ]);
      await backend.ask("name this chat", model: "fake-model", provider: "fake");

      await send(backend, "hello there");

      expect(client.sent.last.map((m) => m.text).join(), isNot(contains("An answer")));
      expect(client.sent.last.map((m) => m.text).join(), isNot(contains("name this chat")));
    });
  });

  group("what the app asks it", () {
    test("the model list is whatever the providers offer", () async {
      final backend = backendOver([]);

      expect(await backend.models(), [
        const ModelOption(providerId: "fake", modelId: "fake-model", label: "fake · fake-model"),
      ]);
    });

    test("shutting down closes the clients it opened", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi");
      await backend.shutdown();

      expect(client.closed, isTrue);
    });
  });

  /// Auto-memory on over the default store; [bg] adds the background model
  /// pair, [extract] is the sub-gate.
  MemorySettings memory({bool extract = true, bool bg = true}) =>
      MemorySettings(
        autoMemory: true,
        extract: extract,
        memoryDir: config.memoryDir(),
        bgModel: bg ? "fake-model" : null,
        bgProvider: bg ? "fake" : null,
      );

  group("writing memories after a turn", () {
    late MemoryStore store;

    setUp(() => store = MemoryStore(config.fs, config.memoryDir()));

    test("a finished turn leaves the memory the background model kept", () async {
      // The first scripted turn is the agent finishing; the second is the
      // extraction call answering with the one fact it kept.
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": ["the user likes tabs over spaces"]}')],
      ]);

      await send(backend, "how should I indent this", memory: memory());

      await untilMemory(store, "the user likes tabs over spaces");
      final entry = (await store.entries()).single;
      expect(entry.chat, chatId);
    });

    test("an extraction that names nothing writes nothing", () async {
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
      ]);

      await send(backend, "how should I indent this", memory: memory());

      await pumpEvents();
      expect(await store.entries(), isEmpty);
    });

    test("the extraction is asked the exchange and what is already kept",
        () async {
      final existing = await store.add("the user likes tabs over spaces");
      final backend = backendOver([
        [saidOnly("use spaces, the user changed their mind")],
        [saidOnly('{"memories": []}')],
      ]);

      await send(backend, "how should I indent this", memory: memory());

      // The extraction is unwatched background work: polled, not beaten.
      await waitFor(() => client.sent.length >= 2, what: "the extraction call");

      final question = client.sent.last.last;
      expect(question.text, contains("how should I indent this"));
      expect(question.text, contains("use spaces, the user changed their mind"));
      // The kept memory, with the id the replacement ops take.
      expect(question.text, contains("the user likes tabs over spaces"));
      expect(question.text, contains(existing.id));
      expect(question.text, contains("JSON"));
    });

    test("a replacement corrects the kept memory in place", () async {
      final existing = await store.add("the user likes tabs over spaces");
      final backend = backendOver([
        [saidOnly("use spaces, the user changed their mind")],
        [saidOnly(jsonEncode({
          "memories": <String>[],
          "replaces": {existing.id: "the user likes spaces over tabs"},
        }))],
      ]);

      await send(backend, "how should I indent this", memory: memory());

      await untilMemory(store, "the user likes spaces over tabs");
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.id, existing.id);
      expect(entries.single.text, "the user likes spaces over tabs");
      expect(entries.single.chat, chatId);
    });

    test("a delete spends the kept memory", () async {
      final existing = await store.add("a fact that turned out wrong");
      final backend = backendOver([
        [saidOnly("never mind that, it was wrong")],
        [saidOnly(jsonEncode({
          "memories": <String>[],
          "delete": [existing.id],
        }))],
      ]);

      await send(backend, "let me correct the record", memory: memory());

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await store.entries()).isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail("the store never dropped the memory");
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    test("kept facts land as a note the page can see", () async {
      final backend = backendOver([
        [saidOnly("the user likes tabs over spaces")],
        [saidOnly('{"memories": ["the user likes tabs over spaces", "the user is on the west coast"]}')],
      ]);
      final notes = <MemoryNote>[];
      final subscription = backend.memoryNotes.listen(notes.add);

      await send(backend, "a little about me", memory: memory());

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (notes.isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail("the note never landed");
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await subscription.cancel();
      expect(notes.single.chatId, chatId);
      expect(notes.single.text, "Kept 2 memories.");
    });

    test("no note where nothing new was kept", () async {
      final existing = await store.add("the user likes tabs over spaces");
      final backend = backendOver([
        [saidOnly("still tabs, by the way")],
        [saidOnly(jsonEncode({
          "memories": <String>[],
          "replaces": {existing.id: "the user likes tabs over spaces"},
        }))],
      ]);
      final notes = <MemoryNote>[];
      final subscription = backend.memoryNotes.listen(notes.add);

      await send(backend, "how should I indent this", memory: memory());
      await pumpEvents();
      await subscription.cancel();

      expect(notes, isEmpty);
      expect((await store.entries()).single.text, "the user likes tabs over spaces");
    });

    test("no background model, nothing is written", () async {
      final backend = backendOver([
        [finish],
      ]);

      await send(backend, "how should I indent this", memory: memory(bg: false));

      await pumpEvents();
      expect(await store.entries(), isEmpty);
    });

    test("the extract gate off, nothing is written", () async {
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": ["a fact"]}')],
      ]);

      await send(backend, "how should I indent this",
          memory: memory(extract: false));

      await pumpEvents();
      expect(await store.entries(), isEmpty);
    });

    test("an aborted turn writes nothing", () async {
      final backend = backendOver([
        [bashCall("sleep 5")],
        [saidOnly('{"memories": ["a fact"]}')],
      ]);
      final events = <AgentEvent>[];
      final turn = backend
          .sendPrompt(chatId, userMessage("hi", at: sentAt),
              settings: TurnSettings(
                  model: "fake-model",
                  provider: "fake",
                  approveMode: ApproveMode.ask,
                  memory: memory()))
          .listen(events.add);
      await pumpEvents();

      await backend.abort(chatId);
      await turn.cancel();
      await pumpEvents();

      expect(events.whereType<DoneEvent>().single.aborted, isTrue);
      expect(await store.entries(), isEmpty);
    });
  });

  group("tidying the memories in the background", () {
    late MemoryStore store;

    setUp(() => store = MemoryStore(config.fs, config.memoryDir()));

    /// A store grown to [n] facts, one memory each.
    Future<List<MemoryEntry>> seed(int n) async =>
        [for (var i = 0; i < n; i++) await store.add("the user likes thing $i")];

    /// The consolidation's own question, out of what the client was sent.
    String tidyQuestion() {
      for (final call in client.sent) {
        final asked =
            [for (final m in call) m.text].where((t) => t.contains("Tidy")).toList();
        if (asked.length == 1) return asked.single;
      }
      fail("the consolidation was never asked");
    }

    /// The pass's stamp is what says it is done: whatever it wrote is in by
    /// the time it leaves one.
    Future<void> untilStamped() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (await store.lastConsolidated() == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail("the pass never stamped");
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test("a store that has not grown is never asked to be tidied", () async {
      await seed(3);
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
      ]);

      await send(backend, "hello again", memory: memory());

      await pumpEvents();
      expect(client.sent, hasLength(2));
      expect(await store.lastConsolidated(), isNull);
    });

    test("a grown store is merged and pruned behind the turn", () async {
      final entries = await seed(consolidationMinEntries);
      final keep = entries.first;
      final spend = entries[1];
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
        [saidOnly(jsonEncode({
          "memories": <String>[],
          "replaces": {keep.id: "the user likes things one and two"},
          "delete": [spend.id],
        }))],
      ]);

      await send(backend, "hello again", memory: memory());

      await untilMemory(store, "the user likes things one and two");
      await untilStamped();
      final texts = [for (final e in await store.entries()) e.text];
      expect(texts, isNot(contains("the user likes thing 1")));
      expect(texts, hasLength(consolidationMinEntries - 1));
      // The pass was asked the whole store.
      final question = tidyQuestion();
      expect(question, contains(entries.last.id));
      expect(question, contains(keep.id));
    });

    test("a tidied store is not asked again inside the interval", () async {
      await seed(consolidationMinEntries);
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
        [saidOnly('{"memories": [], "replaces": {}, "delete": []}')],
        // The second turn: the agent and its extraction, and nothing after.
        [finish],
        [saidOnly('{"memories": []}')],
      ]);

      await send(backend, "one", memory: memory());
      await untilStamped();

      await send(backend, "two", memory: memory());
      await pumpEvents();

      expect(client.sent, hasLength(5));
    });

    test("a pass that finds nothing still stamps its hour", () async {
      await seed(consolidationMinEntries);
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
        [saidOnly('{"memories": [], "replaces": {}, "delete": []}')],
      ]);

      await send(backend, "hello again", memory: memory());
      await untilStamped();

      expect((await store.entries()).length, consolidationMinEntries);
    });

    test("pinned memories are neither offered nor spent", () async {
      // One over the threshold: the pinned entry is not offered, so it is
      // not counted either.
      final entries = await seed(consolidationMinEntries + 1);
      final pinnedEntry = entries.first;
      final spend = entries[1];
      await store.pin(pinnedEntry.id);
      final backend = backendOver([
        [finish],
        [saidOnly('{"memories": []}')],
        [saidOnly(jsonEncode({
          "memories": <String>[],
          "delete": [pinnedEntry.id, spend.id],
        }))],
      ]);

      await send(backend, "hello again", memory: memory());

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((await store.entries()).any((e) => e.id == spend.id)) {
        if (DateTime.now().isAfter(deadline)) {
          fail("the store never spent the memory");
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final remaining = await store.entries();
      expect(remaining.where((e) => e.id == pinnedEntry.id).single.pinned, isTrue);
      expect(tidyQuestion(), isNot(contains(pinnedEntry.id)));
    });
  });

  group("the turn's rules reach the agent", () {
    test("a deny rule refuses the command before the mode", () async {
      final backend = backendOver([
        [bashCall("rm -rf /tmp/entoli-probe")],
        [saidOnly("done")],
      ], respond: (command) => ok("ran"));
      final events = await send(
        backend,
        "run rm -rf /tmp/entoli-probe",
        approveMode: ApproveMode.ask,
        permissions: const [
          PermissionRule(
              tool: "bash", pattern: "rm *", decision: PermissionDecision.deny),
        ],
      );
      expect(shell.ran, isEmpty,
          reason: "a deny rule refuses without running");
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text, contains("permission rule"));
    });
  });
}

/// Let the agent's own async work run before looking at what it has published.
/// Let the turn get as far as it can before the test looks. A prompt now lays
/// down the chat's directories before the agent starts, so a handful of empty
/// microtasks no longer reaches the first tool call.
Future<void> pumpEvents() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A question or an approval is published when the turn's own async hops
/// deliver it — on a loaded runner, more than one [pumpEvents] round's worth
/// of hops, and nothing the turn is wrong about. So the arrival is polled
/// ([read], to a deadline, the event-driven wait [untilMemory] is) and
/// returned once it says something is on screen for the test to act on.
Future<List> untilPending(String what, FutureOr<List> Function() read) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final pending = await read();
    if (pending.isNotEmpty) return pending;
    if (DateTime.now().isAfter(deadline)) {
      fail("$what never went pending");
    }
    await pumpEvents();
  }
}

/// Extraction runs unwatched, so a test polls the store until [want] is in it
/// rather than awaiting the turn — which is over the moment the extraction
/// starts.
Future<void> untilMemory(MemoryStore store, String want) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final entries = await store.entries();
    if ([for (final e in entries) e.text].contains(want)) return;
    if (DateTime.now().isAfter(deadline)) {
      fail("the store never held '$want'; it held "
          "${[for (final e in entries) e.text]}");
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// [inner]'s first answer, held until [gate] completes: a classifier still
/// thinking.
class _Held implements LlmClient {
  _Held(this.inner, this.gate);

  final FakeLlmClient inner;
  final Future<void> gate;

  @override
  Stream<LlmChunk> stream(List<LlmMessage> messages,
      {required String model,
      List<LlmTool> tools = const [],
      double? temperature,
      String? reasoningEffort}) async* {
    final chunks = await inner.stream(messages, model: model, tools: tools).toList();
    if (inner.sent.length == 1) await gate;
    yield* Stream.fromIterable(chunks);
  }

  @override
  Future<List<String>> listModels() => inner.listModels();

  @override
  void close() {}
}
