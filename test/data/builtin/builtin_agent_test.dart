import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/memory/instructions.dart";
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/data/builtin/memory_tools.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/artifact.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  setUp(() => session = BuiltinSession());

  /// The agent under test. [approvals] answers each request in order; without
  /// one, commands run unasked. [saveArtifact] makes the `artifact` tool
  /// available and records what was saved.
  BuiltinAgent agentOver(
    FakeLlmClient client, {
    ShellResult Function(String)? respond,
    List<ApprovalResponse> approvals = const [],
    List<String?>? answers,
    BuiltinOptions options = const BuiltinOptions(),
    ApproveMode approveMode = ApproveMode.never,
    bool canRunCommands = true,
    Future<String> Function(String path, {String? artifactId})? saveArtifact,
    MemorySettings memory = MemorySettings.off,
    List<InstructionFile> instructions = const [],
    MemoryStore? memoryStore,
    String? memoryChat,
  }) {
    final tempDir = Directory.systemTemp.createTempSync("agent-test");
    final testProjectWorkspace = p.join(tempDir.path, "project-workspace");
    // Nested the way the layout is: the chat's own workspace is a folder
    // inside its project's, which is the bound the nested walk stops at.
    final testWorkspace = p.join(testProjectWorkspace, "chats", "chat-1");
    Directory(testWorkspace).createSync(recursive: true);
    addTearDown(() => tempDir.deleteSync(recursive: true));
    shell = FakeShell(respond ?? (_) => ok(""), canRunCommands: canRunCommands);
    final allowed = [...approvals];
    return BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      fs: fileSystemIo,
      workspace: testWorkspace,
      projectWorkspace: testProjectWorkspace,
      model: "fake-model",
      options: options,
      approveMode: approveMode,
      approve: (_) async => allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
      // Nothing picked, unless the test says what was.
      answer: (request) async => answers ?? request.unanswered,
      saveArtifact: saveArtifact,
      memory: memory,
      instructions: instructions,
      memoryStore: memoryStore,
      memoryChat: memoryChat,
    );
  }

  /// A reply with no tool calls ends the turn — the native termination signal.
  final finish = saidOnly("done");

  group("the loop", () {
    test("runs the command the model asked for, in the workspace", () async {
      final client = FakeLlmClient([
        [bashCall("ls -la")],
        [finish],
      ]);
      await agentOver(client).run(userMessage("what is here?")).toList();

      expect(shell.ran, ["ls -la"]);
    });

    test("shows the model what the command produced", () async {
      final client = FakeLlmClient([
        [bashCall("cat notes.txt")],
        [finish],
      ]);
      await agentOver(client, respond: (c) {
        if (c.startsWith("cat")) return ShellResult(returnCode: 2, output: "no such file");
        return ok("");
      }).run(userMessage("read it")).toList();

      final observation = client.sent[1].last;
      expect(observation.role, LlmRole.tool);
      expect(observation.toolCallId, "call-1");
      expect(observation.text, contains("\"returncode\": 2"));
      expect(observation.text, contains("no such file"));
    });

    test("the first turn is the task under two system messages", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      final agent = agentOver(client);
      await agent.run(userMessage("fix the bug")).toList();

      // The body first and this conversation's own directories second: split so
      // the body is one string every chat on the device shares, which is what
      // the on-device cache warms. See [turnPrompt].
      expect(client.sent.first.take(2).map((m) => m.role),
          [LlmRole.system, LlmRole.system]);
      expect(client.sent.first.first.text, contains("TestOS 1.0 test"));
      expect(client.sent.first.first.text, isNot(contains(agent.workspace)));
      expect(client.sent.first[1].text, contains(agent.workspace));
      expect(client.sent.first[2].text, contains("fix the bug"));
    });

    test("a later turn continues the session instead of restarting it", () async {
      final client = FakeLlmClient([
        [finish],
        [finish],
      ]);
      final agent = agentOver(client);
      await agent.run(userMessage("first")).toList();
      await agent.run(userMessage("second")).toList();

      // Rewritten rather than added to: a second turn must not stack another
      // pair of system messages on the first.
      expect(client.sent.last.where((m) => m.role == LlmRole.system), hasLength(2));
      expect(client.sent.last[1].text, contains(agent.workspace));
      expect(client.sent.last.last.text, contains("second"));
      expect(client.sent.last.map((m) => m.text).join(), contains("first"));
    });

    test("an @agent's prompt rides under the system message", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client)
          .run(userMessage("look at it"), agentPrompt: "You only read; you never edit.")
          .toList();

      // In the per-turn message, not the body: an @agent is this turn's, and
      // the body has to stay the same string for every chat.
      expect(client.sent.first.first.text,
          isNot(contains("You only read; you never edit.")));
      expect(client.sent.first[1].text, contains("You only read; you never edit."));
    });

    test("workspace instructions ride the second system message", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(
        client,
        instructions: const [
          InstructionFile(
              path: "/ws/AGENTS.md",
              kind: InstructionKind.project,
              content: "project rules"),
        ],
      ).run(userMessage("hi")).toList();

      // In the per-turn message, not the body: the body has to stay the same
      // string for every chat, which is what the on-device cache warms.
      expect(client.sent.first.first.text, isNot(contains("project rules")));
      expect(client.sent.first[1].text, contains("project rules"));
      expect(client.sent.first[1].text, contains("Workspace instructions"));
    });

    test("no instructions means no instructions section", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client).run(userMessage("hi")).toList();
      expect(client.sent.first[1].text, isNot(contains("Workspace instructions")));
    });
  });

  group("finishing", () {
    test("a reply with no tool calls ends the turn", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.last, isA<DoneEvent>());
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(client.sent, hasLength(1));
    });

    test("the reply text is what the user sees", () async {
      final client = FakeLlmClient([
        [saidOnly("The answer is 42.")],
      ]);
      final events = await agentOver(client).run(userMessage("what is the answer?")).toList();

      expect(events.whereType<TextDelta>().map((e) => e.text), ["The answer is 42."]);
      expect(events.last, isA<DoneEvent>());
    });

    test("a command followed by a text reply runs both", () async {
      final client = FakeLlmClient([
        [bashCall("ls")],
        [saidOnly("Found three files.")],
      ]);
      final events = await agentOver(client, respond: (c) => ok("a b c")).run(userMessage("hi")).toList();

      expect(shell.ran, ["ls"]);
      expect(events.whereType<TextDelta>().map((e) => e.text), ["Found three files."]);
    });
  });

  group("what the UI is told", () {
    test("text and thinking arrive as their own events", () async {
      final client = FakeLlmClient([
        [
          const LlmReasoningChunk("weighing it up"),
          const LlmTextChunk("Looking now."),
          saidOnly("Looking now."),
        ],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ReasoningDelta>().map((e) => e.text), ["weighing it up"]);
      expect(events.whereType<TextDelta>().map((e) => e.text), ["Looking now."]);
      // Closed when the reply started, so the label can say how long it took.
      expect(events.whereType<ReasoningEnd>(), hasLength(1));
      expect(events.whereType<ReasoningEnd>().single.duration, isNotNull);
    });

    // The block has to go back to Anthropic signed, so it is closed holding
    // the signature rather than written again once the response completes.
    test("a signed thinking block is closed with its signature", () async {
      final client = FakeLlmClient([
        [
          const LlmReasoningChunk("weighing it up"),
          const LlmReasoningSignature("sig-abc"),
          const LlmTextChunk("Looking now."),
          saidOnly("Looking now."),
        ],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ReasoningEnd>().single.signature, "sig-abc");
    });

    test("a provider that reports the signature only at the end still keeps it", () async {
      final client = FakeLlmClient([
        [
          const LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              reasoning: "all of it at once",
              reasoningSignature: "sig-late",
              text: "done",
            ),
          ),
        ],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ReasoningEnd>().single.signature, "sig-late");
    });

    // Each is a message the provider has to be handed back whole, so the parts
    // of one have to be told apart from the parts of the next.
    test("every step opens a response of its own", () async {
      final client = FakeLlmClient([
        [bashCall("pwd")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("where am I?")).toList();

      final ids = events.whereType<ResponseStart>().map((e) => e.id).toList();
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(2));
    });

    // The OpenAI shape reports the whole of the thinking on the completion as
    // well as streaming it, so closing the block on both wrote it twice.
    test("thinking that streamed is not closed again by the completion", () async {
      final client = FakeLlmClient([
        [
          const LlmReasoningChunk("weighing it up"),
          const LlmTextChunk("Looking now."),
          const LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              reasoning: "weighing it up",
              text: "Looking now.",
            ),
          ),
        ],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ReasoningEnd>(), hasLength(1));
      expect(events.whereType<ReasoningEnd>().single.duration, isNotNull);
    });

    test("thinking reported only at the end still fills the block", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              reasoning: "all of it at once",
              text: "done",
            ),
          ),
        ],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ReasoningEnd>().single.text, "all of it at once");
    });

    test("a call and its result are reported as a pair", () async {
      final client = FakeLlmClient([
        [bashCall("pwd")],
        [finish],
      ]);
      final events = await agentOver(client, respond: (c) {
        if (c == "pwd") return ok("/tmp/workspace\n");
        return ok("");
      }).run(userMessage("hi")).toList();

      final call = events.whereType<ToolCallEvent>().first.call;
      expect(call.name, "bash");
      expect(call.argumentsText, "pwd");
      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.callId, call.id);
      expect(result.output, "/tmp/workspace\n");
    });
  });

  group("a model that answers in text", () {
    test("ends the turn without calling any tool", () async {
      final client = FakeLlmClient([
        [saidOnly("Here is my answer.")],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(client.sent, hasLength(1));
      expect(events.last, isA<DoneEvent>());
    });
  });

  group("approvals", () {
    test("a command waits for the answer and then runs", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf build")],
        [finish],
      ]);
      final events = await agentOver(client,
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run(userMessage("clean up"))
          .toList();

      expect(events.whereType<ApprovalRequestEvent>().first.approval.toolName, "bash");
      expect(shell.ran, contains("rm -rf build"));
    });

    // The banner asks about the command, not about `bash`, so the wording has
    // to travel with the approval — dug back out of the JSON by whoever draws
    // it, it is a guess at which key this tool used.
    test("the approval says what the call actually does", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf build")],
        [finish],
      ]);
      final events = await agentOver(client,
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run(userMessage("clean up"))
          .toList();

      final approval = events.whereType<ApprovalRequestEvent>().first.approval;
      expect(approval.argumentsText, "rm -rf build");
    });

    test("a denied command is not run, and the model is told why", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf /")],
        [finish],
      ]);
      await agentOver(client,
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.deny, ApprovalResponse.allow])
          .run(userMessage("clean up"))
          .toList();

      expect(shell.ran, isNot(contains("rm -rf /")));
      expect(client.sent[1].last.text, contains("denied"));
    });

    test("nothing is asked when the chat runs without asking", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });
  });

  group("asking the user", () {
    final oneQuestion = {
      "questions": [
        {
          "question": "Which database?",
          "options": [
            {"label": "Postgres"},
            {"label": "SQLite"},
          ],
        },
      ],
    };

    test("the turn waits for the answer and hands it to the model", () async {
      final client = FakeLlmClient([
        [askCall(oneQuestion)],
        [finish],
      ]);
      final events = await agentOver(client, answers: ["Postgres"])
          .run(userMessage("set up storage"))
          .toList();

      final request = events.whereType<QuestionRequestEvent>().single.request;
      expect(request.id, "ask-1");
      expect(request.questions.single.options.map((o) => o.label), ["Postgres", "SQLite"]);

      final answer = client.sent[1].firstWhere((m) => m.toolCallId == "ask-1");
      expect(answer.role, LlmRole.tool);
      expect(answer.text, contains("Postgres"));
      expect(answer.text, contains("Which database?"));
    });

    test("the call and its answer are a pair the conversation keeps", () async {
      final client = FakeLlmClient([
        [askCall(oneQuestion)],
        [finish],
      ]);
      final events = await agentOver(client, answers: ["SQLite"])
          .run(userMessage("set up storage"))
          .toList();

      final call = events.whereType<ToolCallEvent>().first.call;
      expect(call.name, askToolName);
      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.callId, call.id);
      expect(askAnswersFrom(result.output), ["SQLite"]);
    });

    test("nothing picked is reported rather than left out", () async {
      final client = FakeLlmClient([
        [askCall(oneQuestion)],
        [finish],
      ]);
      await agentOver(client).run(userMessage("set up storage")).toList();

      final answer = client.sent[1].firstWhere((m) => m.toolCallId == "ask-1");
      expect(answer.text, contains("Which database?"));
      expect(answer.text, contains("answered nothing"));
    });

    test("a call with nothing askable in it is rejected, not put on screen", () async {
      final client = FakeLlmClient([
        [askCall({"question": "Which one?"})],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<QuestionRequestEvent>(), isEmpty);
      expect(session.messages.firstWhere((m) => m.toolCallId == "ask-1").text,
          contains("needs at least one option"));
    });

    test("asking is offered even where nothing can be run", () async {
      final client = FakeLlmClient([
        [saidOnly("nothing to run")],
      ]);
      await agentOver(client, canRunCommands: false).run(userMessage("hi")).toList();

      // File tools are always offered; bash is dropped without a shell, and
      // ask_user is still there.
      final tools = client.calls.single.tools.map((t) => t.name).toSet();
      expect(tools, containsAll([askToolName, "read", "write", "edit"]));
      expect(tools, isNot(contains("bash")));
      expect(client.sent.first.first.text, contains(askToolName));
    });
  });

  group("limits and failures", () {
    test("a turn that never finishes stops at the step limit", () async {
      final client = FakeLlmClient(List.filled(3, [bashCall("sleep 1")]));
      final events = await agentOver(client,
              options: const BuiltinOptions(stepLimit: 3))
          .run(userMessage("hi"))
          .toList();

      expect(client.sent, hasLength(3));
      expect(events.whereType<ErrorEvent>().single.message, contains("3 steps"));
    });

    test("a retryable failure is announced and then tried again", () async {
      final client = FakeLlmClient([
        [],
        [finish],
      ])..failures[0] = const LlmException("rate limited", statusCode: 429, retryable: true);
      final events = await agentOver(client,
              options: const BuiltinOptions(retryBackoff: Duration.zero))
          .run(userMessage("hi"))
          .toList();

      expect(events.whereType<RetryEvent>().single.attempt, 1);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test("a rejected key is reported rather than retried", () async {
      final client = FakeLlmClient([[]])
        ..failures[0] = const LlmException("bad key", statusCode: 401);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(client.sent, hasLength(1));
      expect(events.whereType<ErrorEvent>().single.message, contains("bad key"));
      expect(events.last, isA<DoneEvent>());
    });

    test("giving up says so once the attempts are used", () async {
      final client = FakeLlmClient([[], [], []]);
      for (var i = 0; i < 3; i++) {
        client.failures[i] = const LlmException("busy", statusCode: 503, retryable: true);
      }
      final events = await agentOver(client,
              options: const BuiltinOptions(maxAttempts: 3, retryBackoff: Duration.zero))
          .run(userMessage("hi"))
          .toList();

      expect(client.sent, hasLength(3));
      expect(events.whereType<RetryEvent>(), hasLength(2));
      expect(events.whereType<ErrorEvent>().single.message, contains("busy"));
    });
  });

  group("every call is answered", () {
    test("a tool that does not exist", () async {
      final client = FakeLlmClient([
        [
          const LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [LlmToolCall(id: "x", name: "python", argumentsJson: "{}")],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("hi")).toList();

      expect(events.whereType<ToolResultEvent>().first.result.exceptionInfo,
          contains("no tool called 'python'"));
      expect(session.messages.firstWhere((m) => m.toolCallId == "x").text,
          contains("`bash` and `$askToolName`"));
    });

    test("arguments that are not the ones the tool takes", () async {
      final client = FakeLlmClient([
        [
          const LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [LlmToolCall(id: "x", name: "bash", argumentsJson: "{oops")],
            ),
          ),
        ],
        [finish],
      ]);
      await agentOver(client).run(userMessage("hi")).toList();

      expect(session.messages.firstWhere((m) => m.toolCallId == "x").text,
          contains("was missing"));
    });
  });

  group("stopping", () {
    test("cancel kills the running command and ends the turn", () async {
      final client = FakeLlmClient([
        [bashCall("npm install")],
        [finish],
      ]);
      final agent = agentOver(client);
      shell.hang.add("npm install");
      final events = <AgentEvent>[];
      final done = agent.run(userMessage("hi")).forEach(events.add);

      await Future<void>.delayed(Duration.zero);
      await agent.cancel();
      await done;

      expect(shell.killed, ["npm install"]);
      expect(client.sent, hasLength(1));
      expect(events.last, isA<DoneEvent>());
    });

    // A call the stop got to first is one the agent knows did not run. Left
    // unreported it is a call with no result in the log, which a reload can
    // only guess about — and guesses cautiously, "may or may not have run".
    // Reporting it is also what keeps the live session and a reload agreeing.
    test("a call the stop beat is reported rather than left to a guess", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: const LlmMessage(role: LlmRole.assistant, toolCalls: [
              LlmToolCall(id: "c1", name: "bash", argumentsJson: '{"command":"first"}'),
              LlmToolCall(id: "c2", name: "bash", argumentsJson: '{"command":"second"}'),
            ]),
          ),
        ],
      ]);
      late BuiltinAgent agent;
      final events = <AgentEvent>[];
      // Stop while the first is running, so the second is never reached.
      final done = (agent = agentOver(client, respond: (command) {
        if (command == "first") unawaited(agent.cancel());
        return ok("");
      })).run(userMessage("do both")).forEach(events.add);
      await done;

      final answered = events.whereType<ToolResultEvent>().toList();
      expect(answered.map((e) => e.result.callId), ["c1", "c2"]);
      expect(answered.last.result.exceptionInfo, contains("not executed"));
      // Paired with its call, or the projection has nothing to hang it on and
      // the model is never told the call went unrun.
      expect(events.whereType<ToolCallEvent>().map((e) => e.call.id), ["c1", "c2"]);
    });
  });

  group("with no shell to run anything", () {
    test("the model is not offered a tool it could never use", () async {
      final client = FakeLlmClient([
        [saidOnly("There is nothing I can run here.")],
      ]);
      await agentOver(client, canRunCommands: false).run(userMessage("hi")).toList();

      expect(client.sent.first.first.text, contains("no shell"));
    });

    test("a reply with no command in it is the answer, not a mistake", () async {
      final client = FakeLlmClient([
        [const LlmTextChunk("Two plus two is four."), saidOnly("Two plus two is four.")],
      ]);
      final events = await agentOver(client, canRunCommands: false).run(userMessage("2+2?")).toList();

      expect(client.sent, hasLength(1));
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(events.last, isA<DoneEvent>());
    });
  });

  group("a session that missed the conversation", () {
    test("carries on from what it was given", () async {
      session.replaceWith(const [
        LlmMessage(role: LlmRole.user, text: "what is 2+2?"),
        LlmMessage(role: LlmRole.assistant, text: "four"),
      ]);
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client).run(userMessage("and 3+3?")).toList();

      expect(client.sent.first.first.role, LlmRole.system);
      expect(client.sent.first.map((m) => m.text).join(), contains("what is 2+2?"));
      expect(client.sent.first.last.text, contains("and 3+3?"));
    });

    test("given nothing, it starts from the task", () async {
      session.replaceWith(const []);
      expect(session.isFresh, isTrue);
    });
  });

  group("carrying on an interrupted turn", () {
    test("says what happened and runs the loop again", () async {
      session.replaceWith(const [
        LlmMessage(role: LlmRole.user, text: "build it"),
        LlmMessage(role: LlmRole.assistant, toolCalls: [
          LlmToolCall(id: "c1", name: "bash", argumentsJson: '{"command":"make"}'),
        ]),
        LlmMessage(role: LlmRole.tool, toolCallId: "c1", text: "interrupted"),
      ]);
      final client = FakeLlmClient([
        [finish],
      ]);
      final events = await agentOver(client).resume().toList();

      expect(client.sent.single.last.role, LlmRole.user);
      expect(client.sent.single.last.text, contains("interrupted before it finished"));
      expect(events.last, isA<DoneEvent>());
    });

    test("the system prompt is rewritten, so an @agent carries on too", () async {
      session.replaceWith(const [
        LlmMessage(role: LlmRole.system, text: "stale"),
        LlmMessage(role: LlmRole.user, text: "research it"),
        LlmMessage(role: LlmRole.assistant, text: "part way"),
      ]);
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client).resume(agentPrompt: "Be brief.").toList();

      expect(client.sent.single.first.role, LlmRole.system);
      expect(client.sent.single[1].text, contains("Be brief."));
      expect(client.sent.single.map((m) => m.text).join(), isNot(contains("stale")));
    });

    // Killed before the model was ever called: the question is still the last
    // thing said, and there is nothing yet to carry on from.
    test("a turn that never got started is just asked again", () async {
      session.replaceWith(const [
        LlmMessage(role: LlmRole.user, text: "what is 2+2?"),
      ]);
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client).resume().toList();

      expect(client.sent.single.last.text, "what is 2+2?");
    });
  });

  group("artifacts", () {
    /// A [saveArtifact] that records what it was given and returns a fake id.
    Future<String> Function(String, {String? artifactId}) saveAndRecord(
      List<({String path, String? artifactId})> saved,
    ) =>
        (path, {artifactId}) async {
          saved.add((path: path, artifactId: artifactId));
          return "art-${saved.length}";
        };

    test("publishes a workspace path and yields an ArtifactEvent", () async {
      final saved = <({String path, String? artifactId})>[];
      final client = FakeLlmClient([
        [artifactCall("report/index.html", title: "Demo")],
        [finish],
      ]);
      final events = await agentOver(client, saveArtifact: saveAndRecord(saved))
          .run(userMessage("show me a demo"))
          .toList();

      expect(saved, hasLength(1));
      expect(saved.first.path, "report/index.html");

      final artifactEvent = events.whereType<ArtifactEvent>().single;
      expect(artifactEvent.title, "Demo");
      expect(artifactEvent.entryFile, "index.html");
      expect(artifactEvent.artifactId, "art-1");

      // The call/result pair reaches the UI.
      expect(events.whereType<ToolCallEvent>(), hasLength(1));
      expect(events.whereType<ToolResultEvent>(), hasLength(1));
      expect(events.whereType<ToolResultEvent>().single.result.returnCode, 0);

      // The session was answered, so the next turn is not rejected.
      final toolMsg = session.messages.lastWhere((m) => m.toolCallId == "art-1");
      expect(toolMsg.role, LlmRole.tool);
    });

    test("updates in place when artifact_id is passed", () async {
      final saved = <({String path, String? artifactId})>[];
      final client = FakeLlmClient([
        [artifactCall("report/index.html", artifactId: "existing-id")],
        [finish],
      ]);
      await agentOver(client, saveArtifact: saveAndRecord(saved))
          .run(userMessage("update it"))
          .toList();

      expect(saved.first.artifactId, "existing-id");
      expect(saved.first.artifactId, isNotNull);
    });

    test("rejects a call with no path argument", () async {
      final saved = <({String path, String? artifactId})>[];
      final client = FakeLlmClient([
        [LlmCompletion(
          message: LlmMessage(
            role: LlmRole.assistant,
            toolCalls: [
              LlmToolCall(id: "bad", name: artifactToolName, argumentsJson: "{}"),
            ],
          ),
        )],
        [finish],
      ]);
      final events = await agentOver(client, saveArtifact: saveAndRecord(saved))
          .run(userMessage("show me"))
          .toList();

      expect(saved, isEmpty);
      expect(events.whereType<ToolResultEvent>().single.result.returnCode, -1);
      expect(events.whereType<ArtifactEvent>(), isEmpty);
    });

    test("the tool is dropped when saveArtifact is null", () async {
      final client = FakeLlmClient([
        [artifactCall("report/index.html")],
        [finish],
      ]);
      await agentOver(client).run(userMessage("show me")).toList();

      // The tool was not offered.
      final tools = client.calls.first.tools.map((t) => t.name).toList();
      expect(tools, isNot(contains(artifactToolName)));
    });
  });

  group("file tools", () {
    test("write creates a file and read reads it back", () async {
      final client = FakeLlmClient([
        [writeCall("hello.txt", "hello world")],
        [readCall("hello.txt")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("write and read")).toList();

      // Both calls succeeded.
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results, hasLength(2));
      expect(results[0].result.returnCode, 0);
      expect(results[0].result.output, contains("Wrote"));
      expect(results[1].result.returnCode, 0);
      expect(results[1].result.output, contains("hello world"));
    });

    test("reading a file pulls in a subdirectory's AGENTS.md when nested is on",
        () async {
      final client = FakeLlmClient([
        [readCall("sub/notes.txt")],
        [finish],
      ]);
      final agent = agentOver(client, memory: const MemorySettings(nested: true));
      Directory(p.join(agent.workspace, "sub")).createSync(recursive: true);
      File(p.join(agent.workspace, "sub", "notes.txt")).writeAsStringSync("hi");
      File(p.join(agent.workspace, "sub", "AGENTS.md"))
          .writeAsStringSync("sub rules");

      final events = await agent.run(userMessage("read it")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.output, contains("hi"));
      expect(result.output, contains("sub rules"));
      expect(result.output, contains("instructions for this directory"));
    });

    test("nested instructions are not injected when the gate is off", () async {
      final client = FakeLlmClient([
        [readCall("sub/notes.txt")],
        [finish],
      ]);
      final agent = agentOver(client);
      Directory(p.join(agent.workspace, "sub")).createSync(recursive: true);
      File(p.join(agent.workspace, "sub", "notes.txt")).writeAsStringSync("hi");
      File(p.join(agent.workspace, "sub", "AGENTS.md"))
          .writeAsStringSync("sub rules");

      final events = await agent.run(userMessage("read it")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.output, contains("hi"));
      expect(result.output, isNot(contains("sub rules")));
    });

    test("edit replaces a unique string", () async {
      final client = FakeLlmClient([
        [writeCall("test.txt", "foo bar baz")],
        [editCall("test.txt", "bar", "qux")],
        [readCall("test.txt")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("write, edit, read")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[1].result.returnCode, 0);
      expect(results[1].result.output, contains("replaced 1"));
      expect(results[2].result.output, contains("foo qux baz"));
    });

    test("edit rejects a non-unique string without replace_all", () async {
      final client = FakeLlmClient([
        [writeCall("test.txt", "a a a")],
        [editCall("test.txt", "a", "b")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("write and edit")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[1].result.returnCode, -1);
      expect(results[1].result.exceptionInfo, contains("3 times"));
    });

    test("edit with replace_all replaces all occurrences", () async {
      final client = FakeLlmClient([
        [writeCall("test.txt", "a a a")],
        [editCall("test.txt", "a", "b", replaceAll: true)],
        [readCall("test.txt")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("write, edit, read")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[1].result.returnCode, 0);
      expect(results[1].result.output, contains("replaced 3"));
      expect(results[2].result.output, contains("b b b"));
    });

    test("read with offset and limit reads a slice", () async {
      final client = FakeLlmClient([
        [writeCall("lines.txt", "line1\nline2\nline3\nline4\nline5")],
        [readCall("lines.txt", offset: 2, limit: 2)],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("write and read")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[1].result.output, contains("2: line2"));
      expect(results[1].result.output, contains("3: line3"));
      expect(results[1].result.output, isNot(contains("line1")));
      expect(results[1].result.output, isNot(contains("line4")));
    });

    test("project: prefix writes to the project workspace", () async {
      final client = FakeLlmClient([
        [writeCall("project:shared.txt", "from project")],
        [finish],
      ]);
      final agent = agentOver(client);
      await agent.run(userMessage("write to project")).toList();

      expect(File(p.join(agent.projectWorkspace, "shared.txt")).readAsStringSync(), "from project");
      expect(File(p.join(agent.workspace, "shared.txt")).existsSync(), isFalse);
    });

    test("read on a missing file returns an error", () async {
      final client = FakeLlmClient([
        [readCall("nope.txt")],
        [finish],
      ]);
      final events = await agentOver(client).run(userMessage("read missing")).toList();

      expect(events.whereType<ToolResultEvent>().single.result.returnCode, -1);
      expect(events.whereType<ToolResultEvent>().single.result.exceptionInfo, contains("not found"));
    });

    test("file tools are always offered, even without a shell", () async {
      final client = FakeLlmClient([
        [writeCall("test.txt", "hi")],
        [finish],
      ]);
      await agentOver(client, canRunCommands: false).run(userMessage("write")).toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(["read", "write", "edit"]));
      expect(tools, isNot(contains("bash")));
    });
  });

  group("memory tools", () {
    late Directory tmp;
    late MemoryStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync("agent_memory_test_");
      store = MemoryStore(fileSystemIo, p.join(tmp.path, "memory"));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test("the tools are offered only where there is a store", () async {
      final without = FakeLlmClient([[finish]]);
      await agentOver(without).run(userMessage("hi")).toList();
      final withoutTools = without.calls.first.tools.map((t) => t.name).toSet();
      expect(withoutTools, isNot(contains(memorySaveToolName)));
      expect(withoutTools, isNot(contains(memorySearchToolName)));

      final with_ = FakeLlmClient([[finish]]);
      await agentOver(with_, memoryStore: store)
          .run(userMessage("hi"))
          .toList();
      final withTools = with_.calls.first.tools.map((t) => t.name).toSet();
      expect(
          withTools,
          containsAll([
            memorySaveToolName,
            memorySearchToolName,
            memoryUpdateToolName,
            memoryDeleteToolName,
          ]));
    });

    test("memory_save appends to the store, stamped with the chat", () async {
      final client = FakeLlmClient([
        [fileCall(memorySaveToolName, {"text": "the user prefers tabs"})],
        [finish],
      ]);
      final events = await agentOver(client, memoryStore: store, memoryChat: "chat-1")
          .run(userMessage("remember this"))
          .toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, 0);
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.text, "the user prefers tabs");
      expect(entries.single.chat, "chat-1");
    });

    test("memory_save refuses an empty text", () async {
      final client = FakeLlmClient([
        [fileCall(memorySaveToolName, {"text": "   "})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("save")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, -1);
      expect(await store.entries(), isEmpty);
    });

    test("memory_search returns the memories it is about", () async {
      await store.add("the user prefers tabs over spaces");
      await store.add("notes about the weather");

      final client = FakeLlmClient([
        [fileCall(memorySearchToolName, {"query": "how does the user like code"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("look it up")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("the user prefers tabs over spaces"));
      expect(result.output, isNot(contains("notes about the weather")));
    });

    test("memory_search shows the ids the correction tools take", () async {
      final entry = await store.add("the user prefers tabs over spaces");

      final client = FakeLlmClient([
        [fileCall(memorySearchToolName, {"query": "how does the user like code"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("look it up")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.output, contains("[${entry.id}]"));
    });

    test("memory_update replaces the fact in place, stamped with the chat",
        () async {
      final entry = await store.add("the user prefers tabs");

      final client = FakeLlmClient([
        [fileCall(memoryUpdateToolName,
            {"id": entry.id, "text": "the user prefers spaces"})],
        [finish],
      ]);
      final events = await agentOver(client, memoryStore: store, memoryChat: "chat-2")
          .run(userMessage("correct the note"))
          .toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, 0);
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.id, entry.id);
      expect(entries.single.text, "the user prefers spaces");
      expect(entries.single.chat, "chat-2");
    });

    test("memory_update refuses a missing argument", () async {
      final client = FakeLlmClient([
        [fileCall(memoryUpdateToolName, {"text": "no id given"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("update")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, -1);
      expect(await store.entries(), isEmpty);
    });

    test("memory_delete drops the fact, and a missing id is a no-op", () async {
      final entry = await store.add("a fact that is wrong");
      await store.add("a fact that stands");

      final client = FakeLlmClient([
        [fileCall(memoryDeleteToolName, {"id": entry.id})],
        [fileCall(memoryDeleteToolName, {"id": "no-such-id"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("clean up")).toList();

      final results = events.whereType<ToolResultEvent>().map((e) => e.result).toList();
      expect(results.map((r) => r.returnCode), [0, 0]);
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.text, "a fact that stands");
    });

    test("memory_search answers nothing where nothing matches", () async {
      await store.add("notes about the weather");

      final client = FakeLlmClient([
        [fileCall(memorySearchToolName, {"query": "completely unrelated words"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("look it up")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("No memories match"));
    });
  });
}
