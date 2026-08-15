import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/miniswe/llm/llm_client.dart";
import "package:agent_chat/data/miniswe/llm/llm_registry.dart";
import "package:agent_chat/data/miniswe/miniswe_agent.dart";
import "package:agent_chat/data/miniswe/miniswe_backend.dart";
import "package:agent_chat/data/miniswe/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/shell.dart";

import "../../harness.dart";
import "miniswe_fakes.dart";

void main() {
  const chatId = "chat-1";
  late AppConfig config;
  late FakeLlmClient client;
  late FakeShell shell;
  late List<LlmProviderConfig> providers;

  final finish = bashCall("echo $submitMarker", id: "done");
  ShellResult submitted(String command) =>
      command.contains(submitMarker) ? ok("$submitMarker\n") : ok("");

  setUp(() {
    config = tempConfig("agent_chat_miniswe_");
    providers = const [
      LlmProviderConfig(
        id: "fake",
        api: LlmApi.openai,
        baseUrl: "https://example.test/v1",
        models: ["fake-model"],
      ),
    ];
  });

  MinisweBackend backendOver(
    List<List<LlmChunk>> turns, {
    ShellResult Function(String)? respond,
    PromptLibrary? library,
    MinisweOptions options = const MinisweOptions(),
  }) {
    client = FakeLlmClient(turns);
    shell = FakeShell(respond ?? submitted);
    return MinisweBackend(
      config: config,
      library: library,
      shell: shell,
      options: options,
      registry: LlmRegistry(
        providers: () => providers,
        lookupEnv: (_) => null,
        build: (_, _) => client,
      ),
    );
  }

  /// Most of these are not about approvals, so the default here is the chat
  /// setting that does not stop to ask.
  Future<List<AgentEvent>> send(
    MinisweBackend backend,
    String text, {
    String? model = "fake-model",
    String? provider = "fake",
  }) =>
      backend
          .sendPrompt(chatId, text,
              model: model, provider: provider, approveCommands: false)
          .toList();

  /// A turn left running for the test to answer, whether what it stops on is a
  /// command to approve or a question to pick from.
  Stream<AgentEvent> asking(MinisweBackend backend, String text,
          {bool approveCommands = true}) =>
      backend.sendPrompt(chatId, text,
          model: "fake-model", provider: "fake", approveCommands: approveCommands);

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

      expect(config.workspaceDir(chatId).existsSync(), isTrue);
      expect(client.sent.first.first.text, contains(config.workspaceDir(chatId).path));
    });

    test("the model is told about the project workspace it shares", () async {
      final backend = backendOver([
        [finish],
      ]);
      await send(backend, "hi");

      expect(config.projectWorkspaceDir().existsSync(), isTrue);
      expect(client.sent.first.first.text, contains(config.projectWorkspaceDir().path));
    });

    test("a chat in a project works in that project's directories", () async {
      final backend = backendOver([
        [finish],
      ]);
      await backend
          .sendPrompt(chatId, "hi",
              model: "fake-model",
              provider: "fake",
              project: "work",
              approveCommands: false)
          .toList();

      final system = client.sent.first.first.text;
      expect(system, contains(config.workspaceDir(chatId, project: "work").path));
      expect(system, contains(config.projectWorkspaceDir(project: "work").path));
      expect(config.projectWorkspaceDir(project: "work").existsSync(), isTrue);
    });
  });

  group("commands and agents", () {
    PromptLibrary libraryWith(CompletionKind kind, String name, String body) =>
        PromptLibrary([PromptDocument.parse(kind, name, "---\ndescription: d\n---\n\n$body")]);

    test("/name expands to the command's template", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.command, "review", "Review this:\n\n\$ARGUMENTS"),
      );
      await send(backend, "/review the parser");

      expect(client.sent.first[1].text, contains("Review this:\n\nthe parser"));
      expect(client.sent.first[1].text, isNot(contains(r"$ARGUMENTS")));
    });

    test("a command with no placeholder gets its arguments appended", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.command, "commit", "Commit what changed."),
      );
      await send(backend, "/commit only the tests");

      expect(client.sent.first[1].text, contains("Commit what changed."));
      expect(client.sent.first[1].text, contains("only the tests"));
    });

    test("a name the library does not know is left as the prose it probably is", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.command, "review", "Review this."),
      );
      await send(backend, "/etc/hosts is where?");

      expect(client.sent.first[1].text, contains("/etc/hosts is where?"));
    });

    test("@name puts that agent's prompt under the system message", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.agent, "researcher", "You only read."),
      );
      await send(backend, "@researcher where is the parser?");

      expect(client.sent.first.first.text, contains("You only read."));
      expect(client.sent.first[1].text, contains("@researcher where is the parser?"));
    });

    test("an email address is not a mention", () async {
      final backend = backendOver(
        [
          [finish],
        ],
        library: libraryWith(CompletionKind.agent, "example", "You only read."),
      );
      await send(backend, "write to me@example.com");

      expect(client.sent.first.first.text, isNot(contains("You only read.")));
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
      // The command that ends the turn is a command too, and asks in its turn.
      await pumpEvents();
      for (final next in await backend.pendingApprovals(chatId)) {
        await backend.respondApproval(chatId, next.id, ApprovalResponse.allow);
      }
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
      await pumpEvents();
      for (final pending in await backend.pendingApprovals(chatId)) {
        await backend.respondApproval(chatId, pending.id, ApprovalResponse.allow);
      }
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

      expect(shell.ran, ["ls", "echo $submitMarker"]);
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

      final turn = asking(backend, "set up storage", approveCommands: false).toList();

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

      await asking(backend, "set up storage", approveCommands: false).listen((event) {
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

      final turn = asking(backend, "set up storage", approveCommands: false).toList();
      await pumpEvents();
      expect(backend.pendingQuestions(chatId), hasLength(1));

      await backend.abort(chatId);
      await turn.timeout(const Duration(seconds: 5));

      expect(backend.pendingQuestions(chatId), isEmpty);
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
      expect(client.sent.last.last.text, "second");
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
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "what is 2+2?")],
        ),
        Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "four")],
        ),
      ]);
      await send(backend, "and 3+3?");

      final transcript = client.sent.last.map((m) => m.text).join("\n");
      expect(transcript, contains("what is 2+2?"));
      expect(transcript, contains("four"));
      expect(transcript, isNot(contains("first")));
    });

    test("a rewound turn names the files it is not resending", () async {
      final backend = backendOver([
        [finish],
      ]);
      await backend.resetSession(chatId, history: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: DateTime(2026),
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
    test("its patience outlasts the longest command it would allow", () async {
      final backend = backendOver([],
          options: const MinisweOptions(commandTimeout: Duration(seconds: 120)));

      expect(backend.stallTimeout, greaterThan(const Duration(seconds: 120)));
    });

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
Future<void> pumpEvents() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
