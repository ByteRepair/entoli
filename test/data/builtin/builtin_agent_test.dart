import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  setUp(() => session = BuiltinSession());

  /// The agent under test. [approvals] answers each request in order; without
  /// one, commands run unasked.
  BuiltinAgent agentOver(
    FakeLlmClient client, {
    ShellResult Function(String)? respond,
    List<ApprovalResponse> approvals = const [],
    List<String?>? answers,
    BuiltinOptions options = const BuiltinOptions(),
    ApproveMode approveMode = ApproveMode.never,
    bool canRunCommands = true,
  }) {
    shell = FakeShell(respond ?? (_) => ok(""), canRunCommands: canRunCommands);
    final allowed = [...approvals];
    return BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      workspace: "/tmp/workspace",
      projectWorkspace: "/tmp/project-workspace",
      model: "fake-model",
      options: options,
      approveMode: approveMode,
      approve: (_) async => allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
      // Nothing picked, unless the test says what was.
      answer: (request) async => answers ?? request.unanswered,
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
      await agentOver(client).run("what is here?").toList();

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
      }).run("read it").toList();

      final observation = client.sent[1].last;
      expect(observation.role, LlmRole.tool);
      expect(observation.toolCallId, "call-1");
      expect(observation.text, contains("\"returncode\": 2"));
      expect(observation.text, contains("no such file"));
    });

    test("the first turn is the task under the system prompt", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client).run("fix the bug").toList();

      expect(client.sent.first.first.role, LlmRole.system);
      expect(client.sent.first.first.text, contains("/tmp/workspace"));
      expect(client.sent.first.first.text, contains("TestOS 1.0 test"));
      expect(client.sent.first[1].text, contains("fix the bug"));
    });

    test("a later turn continues the session instead of restarting it", () async {
      final client = FakeLlmClient([
        [finish],
        [finish],
      ]);
      final agent = agentOver(client);
      await agent.run("first").toList();
      await agent.run("second").toList();

      expect(client.sent.last.where((m) => m.role == LlmRole.system), hasLength(1));
      expect(client.sent.last.first.text, contains("/tmp/workspace"));
      expect(client.sent.last.last.text, "second");
      expect(client.sent.last.map((m) => m.text).join(), contains("first"));
    });

    test("an @agent's prompt rides under the system message", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client)
          .run("look at it", agentPrompt: "You only read; you never edit.")
          .toList();

      expect(client.sent.first.first.text, contains("You only read; you never edit."));
    });
  });

  group("finishing", () {
    test("a reply with no tool calls ends the turn", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      final events = await agentOver(client).run("hi").toList();

      expect(events.last, isA<DoneEvent>());
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(client.sent, hasLength(1));
    });

    test("the reply text is what the user sees", () async {
      final client = FakeLlmClient([
        [saidOnly("The answer is 42.")],
      ]);
      final events = await agentOver(client).run("what is the answer?").toList();

      expect(events.whereType<TextDelta>().map((e) => e.text), ["The answer is 42."]);
      expect(events.last, isA<DoneEvent>());
    });

    test("a command followed by a text reply runs both", () async {
      final client = FakeLlmClient([
        [bashCall("ls")],
        [saidOnly("Found three files.")],
      ]);
      final events = await agentOver(client, respond: (c) => ok("a b c")).run("hi").toList();

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
      final events = await agentOver(client).run("hi").toList();

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
      final events = await agentOver(client).run("hi").toList();

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
      final events = await agentOver(client).run("hi").toList();

      expect(events.whereType<ReasoningEnd>().single.signature, "sig-late");
    });

    // Each is a message the provider has to be handed back whole, so the parts
    // of one have to be told apart from the parts of the next.
    test("every step opens a response of its own", () async {
      final client = FakeLlmClient([
        [bashCall("pwd")],
        [finish],
      ]);
      final events = await agentOver(client).run("where am I?").toList();

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
      final events = await agentOver(client).run("hi").toList();

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
      final events = await agentOver(client).run("hi").toList();

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
      }).run("hi").toList();

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
      final events = await agentOver(client).run("hi").toList();

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
          .run("clean up")
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
          .run("clean up")
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
          .run("clean up")
          .toList();

      expect(shell.ran, isNot(contains("rm -rf /")));
      expect(client.sent[1].last.text, contains("denied"));
    });

    test("nothing is asked when the chat runs without asking", () async {
      final client = FakeLlmClient([
        [finish],
      ]);
      final events = await agentOver(client).run("hi").toList();

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
          .run("set up storage")
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
          .run("set up storage")
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
      await agentOver(client).run("set up storage").toList();

      final answer = client.sent[1].firstWhere((m) => m.toolCallId == "ask-1");
      expect(answer.text, contains("Which database?"));
      expect(answer.text, contains("answered nothing"));
    });

    test("a call with nothing askable in it is rejected, not put on screen", () async {
      final client = FakeLlmClient([
        [askCall({"question": "Which one?"})],
        [finish],
      ]);
      final events = await agentOver(client).run("hi").toList();

      expect(events.whereType<QuestionRequestEvent>(), isEmpty);
      expect(session.messages.firstWhere((m) => m.toolCallId == "ask-1").text,
          contains("needs at least one option"));
    });

    test("asking is offered even where nothing can be run", () async {
      final client = FakeLlmClient([
        [saidOnly("nothing to run")],
      ]);
      await agentOver(client, canRunCommands: false).run("hi").toList();

      expect(client.calls.single.tools.map((t) => t.name), [askToolName]);
      expect(client.sent.first.first.text, contains(askToolName));
    });
  });

  group("limits and failures", () {
    test("a turn that never finishes stops at the step limit", () async {
      final client = FakeLlmClient(List.filled(3, [bashCall("sleep 1")]));
      final events = await agentOver(client,
              options: const BuiltinOptions(stepLimit: 3))
          .run("hi")
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
          .run("hi")
          .toList();

      expect(events.whereType<RetryEvent>().single.attempt, 1);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });

    test("a rejected key is reported rather than retried", () async {
      final client = FakeLlmClient([[]])
        ..failures[0] = const LlmException("bad key", statusCode: 401);
      final events = await agentOver(client).run("hi").toList();

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
          .run("hi")
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
      final events = await agentOver(client).run("hi").toList();

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
      await agentOver(client).run("hi").toList();

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
      final done = agent.run("hi").forEach(events.add);

      await Future<void>.delayed(Duration.zero);
      await agent.cancel();
      await done;

      expect(shell.killed, ["npm install"]);
      expect(client.sent, hasLength(1));
      expect(events.last, isA<DoneEvent>());
    });
  });

  group("with no shell to run anything", () {
    test("the model is not offered a tool it could never use", () async {
      final client = FakeLlmClient([
        [saidOnly("There is nothing I can run here.")],
      ]);
      await agentOver(client, canRunCommands: false).run("hi").toList();

      expect(client.sent.first.first.text, contains("no shell"));
    });

    test("a reply with no command in it is the answer, not a mistake", () async {
      final client = FakeLlmClient([
        [const LlmTextChunk("Two plus two is four."), saidOnly("Two plus two is four.")],
      ]);
      final events = await agentOver(client, canRunCommands: false).run("2+2?").toList();

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
      await agentOver(client).run("and 3+3?").toList();

      expect(client.sent.first.first.role, LlmRole.system);
      expect(client.sent.first.map((m) => m.text).join(), contains("what is 2+2?"));
      expect(client.sent.first.last.text, "and 3+3?");
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
      expect(client.sent.single.first.text, contains("Be brief."));
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
}
