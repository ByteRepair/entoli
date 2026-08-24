import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "dart:convert";

import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/builtin_backend.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/llm_registry.dart";
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/local/file_sub_agent_log.dart";
import "package:agent_chat/domain/agent_backend.dart";
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
      ),
    ];
  });

  BuiltinBackend backendOver(
    List<List<LlmChunk>> turns, {
    ShellResult Function(String)? respond,
    PromptLibrary? library,
    BuiltinOptions options = const BuiltinOptions(),
  }) {
    client = FakeLlmClient(turns);
    shell = FakeShell(respond ?? okEmpty);
    return BuiltinBackend(
      config: config,
      library: library,
      shell: shell,
      webSearch: FakeWebSearch(),
      store: FileChatStore(config),
      options: options,
      registry: LlmRegistry(
        endpoints: () =>
            [for (final p in providers) LlmEndpoint(p, build: (_, _) => client)],
        lookupEnv: (_) => null,
      ),
    );
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
    List<Message> history = const [],
    List<MessagePart> files = const [],
    Map<String, String> documents = const {},
    DateTime? at,
    MemorySettings memory = MemorySettings.off,
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
                  approveMode: ApproveMode.never,
                  memory: memory))
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

    test("a provider that is not configured is named", () async {
      final backend = backendOver([]);
      final events = await send(backend, "hi", provider: "ghost");

      expect(events.whereType<ErrorEvent>().single.message, contains("'ghost' is not configured"));
    });

    test("a provider with one model does not need it pinned as well", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi", model: null);

      expect(client.calls.single.model, "fake-model");
    });

    test("a provider with no models and nothing pinned cannot be guessed at", () async {
      providers = const [
        LlmProviderConfig(id: "fake", api: LlmApi.openai, baseUrl: "https://example.test/v1"),
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

    test("workspace instructions are loaded and sent when the gate is on",
        () async {
      final backend = backendOver([
        [finish],
      ]);
      // The chat workspace is created by the turn; the project workspace is
      // where the AGENTS.md the loader should find lives.
      Directory(config.projectWorkspaceDir()).createSync(recursive: true);
      File(p.join(config.projectWorkspaceDir(), "AGENTS.md"))
          .writeAsStringSync("project rules");

      await send(backend, "hi",
          memory: const MemorySettings(instructions: true));

      expect(client.sent.first[1].text, contains("project rules"));
      expect(client.sent.first[1].text, contains("Workspace instructions"));
    });

    test("no instructions section when the gate is off", () async {
      final backend = backendOver([
        [finish],
      ]);
      Directory(config.projectWorkspaceDir()).createSync(recursive: true);
      File(p.join(config.projectWorkspaceDir(), "AGENTS.md"))
          .writeAsStringSync("project rules");

      await send(backend, "hi");

      expect(client.sent.first[1].text, isNot(contains("project rules")));
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
      // is not specific enough.
      expect(system, isNot(contains("notes about the weather")));
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
  });

  group("commands and agents", () {
    PromptLibrary libraryWith(CompletionKind kind, String name, String body) =>
        PromptLibrary([PromptDocument.parse(kind, name, "---\ndescription: d\n---\n\n$body")]);

    test("/name expands to the command's template", () async {
      final asWritten =
          libraryWith(CompletionKind.command, "review", "Review this:\n\n\$ARGUMENTS");
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
          libraryWith(CompletionKind.command, "commit", "Commit what changed.");
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
        library: libraryWith(CompletionKind.command, "review", "Review this."),
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
      final asWritten = libraryWith(CompletionKind.command, "review", "Look hard at:\n\n\$ARGUMENTS");
      final backend = backendOver(
        [
          [finish],
        ],
        // The library the turn is replayed against says something else
        // entirely, and a deleted command would say nothing at all.
        library: libraryWith(CompletionKind.command, "review", "REWRITTEN"),
      );
      await send(backend, "/review the parser",
          documents: promptDocuments("/review the parser", asWritten));

      expect(client.sent.first[2].text, contains("Look hard at:\n\nthe parser"));
      expect(client.sent.first[2].text, isNot(contains("REWRITTEN")));
    });

    test("a command deleted since still reads back", () async {
      final asWritten = libraryWith(CompletionKind.command, "review", "Review this.");
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
      final backend = backendOver([], respond: (_) => ok("hello\n"));
      final events = await send(backend, "!echo hello");

      expect(shell.ran, ["echo hello"]);
      expect(client.sent, isEmpty);
      final run = events.whereType<ShellRunEvent>().single.run;
      expect((run.command, run.returnCode, run.output), ("echo hello", 0, "hello\n"));
      expect(events.last, isA<DoneEvent>());
    });

    test("what it exited with comes back with it", () async {
      final backend = backendOver([],
          respond: (_) => const ShellResult(returnCode: 2, output: "no such file"));
      final events = await send(backend, "!cat nothing");

      expect(events.whereType<ShellRunEvent>().single.run.returnCode, 2);
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
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test("it runs in the chat's own workspace, with the project's for a home",
        () async {
      final backend = backendOver([], respond: (_) => ok(""));
      await send(backend, "!pwd");

      expect(shell.cwds, [config.workspaceDir(chatId)]);
      expect(shell.homes, [config.projectWorkspaceDir()]);
      expect(Directory(config.workspaceDir(chatId)).existsSync(), isTrue);
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
      // read again. See "The projection" in `lib/domain/CLAUDE.md`.
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

      await pumpEvents();
      final pending = await backend.pendingApprovals(chatId);
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
      await pumpEvents();
      final first = (await backend.pendingApprovals(chatId)).single;
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
      await pumpEvents();
      expect(await backend.pendingApprovals(chatId), hasLength(1));

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

      await pumpEvents();
      final pending = backend.pendingQuestions(chatId).single;
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
      await pumpEvents();
      expect(backend.pendingQuestions(chatId), hasLength(1));

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

    test("the parent is shown the answer, not that it was interrupted", () async {
      await seedKilledSubAgent("task-1", "halfway");
      final backend = backendOver([
        [saidOnly("there are three")],
        [finish],
      ]);

      await resuming(backend, historyWithPendingTask());

      // The parent's own call is the second: the first is the revived
      // sub-agent's. What answers its `task` call is the sub-agent's output.
      final answered = client.sent.last
          .where((m) => m.role == LlmRole.tool && m.toolCallId == "task-1");
      expect(answered.single.text, contains("there are three"));
      expect(answered.single.text, isNot(contains("interrupted")));
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

    test("disposing a chat forgets it", () async {
      final backend = backendOver([
        [finish],
        [finish],
      ]);
      await send(backend, "first");
      await backend.disposeChat(chatId);
      await send(backend, "second");

      expect(client.sent.last.map((m) => m.text).join(), isNot(contains("first")));
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

    test("a provider that is gone answers nothing rather than failing", () async {
      final backend = backendOver([]);

      expect(await backend.ask("hi", model: "m", provider: "ghost"), isNull);
    });

    test("a request that fails answers nothing either", () async {
      final backend = backendOver([]);
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
