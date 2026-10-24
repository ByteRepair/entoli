import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/image_tool.dart";
import "package:agent_chat/data/builtin/memory/instructions.dart";
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/data/builtin/memory_tools.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/artifact.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/plan.dart";
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
    PermissionClassifier? classifier,
    bool canRunCommands = true,
    Future<String> Function(String path, String entryFile, {String? artifactId})? saveArtifact,
    Future<List<LlmAttachment>> Function(String prompt)? generateImage,
    Future<String> Function(String filename, Uint8List bytes)? saveResource,
    MemorySettings memory = MemorySettings.off,
    List<InstructionFile> instructions = const [],
    MemoryStore? memoryStore,
    String? memoryChat,
    SandboxHelper? sandboxHelper,
    SteerInbox? steers,
    bool seesImages = true,
    bool seesPdfs = false,
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
      classifier: classifier,
      approve: (_) async => allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
      // Nothing picked, unless the test says what was.
      answer: (request) async => answers ?? request.unanswered,
      saveArtifact: saveArtifact,
      generateImage: generateImage,
      saveResource: saveResource,
      memory: memory,
      instructions: instructions,
      memoryStore: memoryStore,
      memoryChat: memoryChat,
      sandboxHelper: sandboxHelper,
      steers: steers,
      seesImages: seesImages,
      seesPdfs: seesPdfs,
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

    test("what rides the second system message, and what does not", () async {
      // An @agent's prompt is this turn's: in the per-turn message, not the
      // body, which has to stay the same string for every chat.
      final client = FakeLlmClient([
        [finish],
      ]);
      await agentOver(client)
          .run(userMessage("look at it"), agentPrompt: "You only read; you never edit.")
          .toList();

      expect(client.sent.first.first.text,
          isNot(contains("You only read; you never edit.")));
      expect(client.sent.first[1].text, contains("You only read; you never edit."));

      // Workspace instructions ride the same message, in a section of theirs.
      final instructed = FakeLlmClient([
        [finish],
      ]);
      await agentOver(
        instructed,
        instructions: const [
          InstructionFile(
              path: "/ws/AGENTS.md",
              kind: InstructionKind.project,
              content: "project rules"),
        ],
      ).run(userMessage("hi")).toList();

      expect(instructed.sent.first.first.text, isNot(contains("project rules")));
      expect(instructed.sent.first[1].text, contains("project rules"));
      expect(instructed.sent.first[1].text, contains("Workspace instructions"));

      // And nothing means no section.
      final plain = FakeLlmClient([
        [finish],
      ]);
      await agentOver(plain).run(userMessage("hi")).toList();
      expect(plain.sent.first[1].text, isNot(contains("Workspace instructions")));
    });
  });

  group("finishing", () {
    test("a reply with no tool calls ends the turn, and is what the user sees",
        () async {
      final client = FakeLlmClient([
        [saidOnly("The answer is 42.")],
      ]);
      final events = await agentOver(client).run(userMessage("what is the answer?")).toList();

      expect(events.whereType<TextDelta>().map((e) => e.text), ["The answer is 42."]);
      expect(events.last, isA<DoneEvent>());
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(client.sent, hasLength(1));
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

  group("steering", () {
    test("a say waiting at a step boundary is read after the results", () async {
      final steers = SteerInbox()..offer(userMessage("use the other file"));
      final client = FakeLlmClient([
        [bashCall("ls")],
        [finish],
      ]);
      final events =
          await agentOver(client, steers: steers).run(userMessage("hi")).toList();

      expect(events.whereType<SteerEvent>().map((e) => e.message.plainText),
          ["use the other file"]);
      // Not before the first call: the prompt had only just gone.
      expect(client.sent[0].where((m) => m.text.contains("other file")), isEmpty);
      final second = client.sent[1];
      expect(second[second.length - 2].role, LlmRole.tool);
      expect(second.last.role, LlmRole.user);
      expect(second.last.text, contains("use the other file"));
    });

    test("a turn that runs no tools leaves what was said unread", () async {
      final steers = SteerInbox()..offer(userMessage("later"));
      final client = FakeLlmClient([
        [finish],
      ]);
      final events =
          await agentOver(client, steers: steers).run(userMessage("hi")).toList();

      expect(events.whereType<SteerEvent>(), isEmpty);
      expect(steers.close().map((m) => m.plainText), ["later"]);
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

  group("approvals", () {
    test("the approval modes ask, or run unasked", () async {
      // Ask: the banner gates the command until the answer.
      final ask = FakeLlmClient([
        [bashCall("rm -rf build")],
        [finish],
      ]);
      final askEvents = await agentOver(ask,
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run(userMessage("clean up"))
          .toList();

      expect(askEvents.whereType<ApprovalRequestEvent>().first.approval.toolName,
          "bash");
      expect(shell.ran, contains("rm -rf build"));

      // Without asking: the same command runs with no banner at all.
      final never = FakeLlmClient([
        [bashCall("rm -rf build")],
        [finish],
      ]);
      final neverEvents =
          await agentOver(never).run(userMessage("clean up")).toList();

      expect(neverEvents.whereType<ApprovalRequestEvent>(), isEmpty,
          reason: "nothing is asked when the chat runs without asking");
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

    test("a command behind an approval banner runs whatever it parses to",
        () async {
      // The banner is the decision, however the run reaches it: a parse
      // vetoing what a person approved is the machine overriding its keeper.
      // In ask mode every command has one.
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')],
        [finish],
      ]);
      await agentOver(client,
              sandboxHelper: _StubSandboxHelper(),
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run(userMessage("go"))
          .toList();

      expect(shell.ran, hasLength(1),
          reason: "the parse does not override an approval the user made");
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
      expect(events.whereType<StepLimitEvent>().single.limit, 3);
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

    test("the parent's options spend one attempt: the controller retries",
        () async {
      final client = FakeLlmClient([[], []]);
      client.failures[0] = const LlmException("busy", statusCode: 503, retryable: true);
      final events = await agentOver(client,
              options: const BuiltinOptions().copyWith(maxAttempts: 1))
          .run(userMessage("hi"))
          .toList();

      expect(client.sent, hasLength(1));
      expect(events.whereType<RetryEvent>(), isEmpty);
      final error = events.whereType<ErrorEvent>().single;
      expect(error.message, contains("busy"));
      expect(error.retryable, isTrue);
    });

    test("the error carries whether the failure was retryable", () async {
      final retryable = FakeLlmClient([[], []])
        ..failures[0] = const LlmException("stream died mid-reply", retryable: true)
        ..failures[1] = const LlmException("stream died mid-reply", retryable: true);
      final events = await agentOver(retryable,
              options: const BuiltinOptions(maxAttempts: 2, retryBackoff: Duration.zero))
          .run(userMessage("hi"))
          .toList();
      expect(events.whereType<ErrorEvent>().single.retryable, isTrue);

      final rejected = FakeLlmClient([[]])
        ..failures[0] = const LlmException("bad key", statusCode: 401);
      final rejectedEvents =
          await agentOver(rejected).run(userMessage("hi")).toList();
      expect(rejectedEvents.whereType<ErrorEvent>().single.retryable, isFalse);
    });
  });

  group("every call is answered", () {
    for (final (what, name, arguments, answer) in [
      ("a tool that does not exist", "python", "{}",
          "no tool called 'python'. The tools you have are `read`"),
      ("arguments that are not the ones the tool takes", "bash", "{oops",
          "was missing"),
      // No sub-agent runner: `task` is not offered, so it is unknown here.
      ("a tool that is not offered", "task",
          '{"agent": "general", "prompt": "go"}', "no tool called 'task'"),
    ]) {
      test(what, () async {
        final client = FakeLlmClient([
          [
            LlmCompletion(
              message: LlmMessage(
                role: LlmRole.assistant,
                toolCalls: [
                  LlmToolCall(id: "x", name: name, argumentsJson: arguments),
                ],
              ),
            ),
          ],
          [finish],
        ]);
        final events = await agentOver(client).run(userMessage("hi")).toList();

        expect(events.whereType<ToolResultEvent>().single.result.exceptionInfo,
            contains(answer));
        expect(session.messages.firstWhere((m) => m.toolCallId == "x").text,
            contains(answer));
      });
    }
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

  group("images", () {
    final cat = LlmAttachment(
        filename: "image-0.png", mimeType: "image/png", bytes: Uint8List(3));
    Future<String> saveTo(List<String> saved, String filename, Uint8List _) async {
      saved.add(filename);
      return "res-$filename";
    }

    test("the tool is offered only with an image model behind it", () async {
      final client = FakeLlmClient([[finish], [finish]]);
      await agentOver(client).run(userMessage("hi")).toList();
      await agentOver(client,
              generateImage: (_) async => [cat],
              saveResource: (_, _) async => "r")
          .run(userMessage("hi"))
          .toList();

      bool offered(int call) =>
          client.calls[call].tools.any((t) => t.name == imageGenerationToolName);
      expect(offered(0), isFalse);
      expect(offered(1), isTrue);
    });

    test("a generated image is saved and recorded on the reply", () async {
      final saved = <String>[];
      final client = FakeLlmClient([
        [fileCall(imageGenerationToolName, {"prompt": "a cat"})],
        [finish],
      ]);
      final events = await agentOver(client,
              generateImage: (prompt) async => prompt == "a cat" ? [cat] : [],
              saveResource: (f, b) => saveTo(saved, f, b))
          .run(userMessage("draw a cat"))
          .toList();

      expect(saved, ["image-0.png"]);
      final part = events.whereType<ImageEvent>().single.part;
      expect(part.resource, "res-image-0.png");
      expect(events.whereType<ToolResultEvent>().single.result.returnCode, 0);
    });

    test("an image model that fails any way fails the call, not the turn", () async {
      final client = FakeLlmClient([
        [fileCall(imageGenerationToolName, {"prompt": "a cat"})],
        [finish],
      ]);
      final events = await agentOver(client,
              generateImage: (_) async => throw const FormatException("not JSON"),
              saveResource: (_, _) async => "r")
          .run(userMessage("draw a cat"))
          .toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, isNot(0));
      expect(result.exceptionInfo, contains("not JSON"));
      expect(client.calls, hasLength(2));
    });

    test("an image the chat model answers with is recorded too", () async {
      final saved = <String>[];
      final client = FakeLlmClient([
        [
          LlmCompletion(
              message: LlmMessage(
                  role: LlmRole.assistant, text: "here", attachments: [cat])),
        ],
      ]);
      final events = await agentOver(client,
              saveResource: (f, b) => saveTo(saved, f, b))
          .run(userMessage("draw a cat"))
          .toList();

      expect(saved, ["image-0.png"]);
      expect(events.whereType<ImageEvent>(), hasLength(1));
    });
  });

  group("artifacts", () {
    /// A [saveArtifact] that records what it was given and returns a fake id.
    Future<String> Function(String, String, {String? artifactId})
        saveAndRecord(
      List<({String path, String? entryFile, String? artifactId})> saved,
    ) =>
        (path, entryFile, {artifactId}) async {
          saved.add((path: path, entryFile: entryFile, artifactId: artifactId));
          return "art-${saved.length}";
        };

    test("publishes a workspace path and yields an ArtifactEvent", () async {
      final saved = <({String path, String? entryFile, String? artifactId})>[];
      final client = FakeLlmClient([
        [artifactCall("report/index.html", title: "Demo")],
        [finish],
      ]);
      final events = await agentOver(client, saveArtifact: saveAndRecord(saved))
          .run(userMessage("show me a demo"))
          .toList();

      expect(saved, hasLength(1));
      expect(saved.first.path, "report/index.html");
      expect(saved.first.entryFile, "index.html");

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
      final saved = <({String path, String? entryFile, String? artifactId})>[];
      final client = FakeLlmClient([
        [artifactCall("report/index.html", artifactId: "existing-id")],
        [finish],
      ]);
      await agentOver(client, saveArtifact: saveAndRecord(saved))
          .run(userMessage("update it"))
          .toList();

      expect(saved.first.artifactId, "existing-id");
      expect(saved.first.entryFile, "index.html");
    });

    test("rejects a call with no path argument", () async {
      final saved = <({String path, String? entryFile, String? artifactId})>[];
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
  });

  group("file tools", () {
    group("read of an image or a PDF", () {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]);
      final pdf = Uint8List.fromList(utf8.encode("%PDF-1.4\n"));

      Future<List<AgentEvent>> read(String name, Uint8List bytes,
          {bool seesImages = true, bool seesPdfs = true, bool canSave = true}) {
        final agent = agentOver(
          FakeLlmClient([
            [readCall(name)],
            [finish],
          ]),
          seesImages: seesImages,
          seesPdfs: seesPdfs,
          saveResource: canSave ? (filename, _) async => "res-$filename" : null,
        );
        File(p.join(agent.workspace, name)).writeAsBytesSync(bytes);
        return agent.run(userMessage("look")).toList();
      }

      test("comes back as the file, between the call and its result", () async {
        for (final (name, bytes, type) in [
          ("shot.png", png, "image/png"),
          ("spec.pdf", pdf, "application/pdf"),
        ]) {
          final events = await read(name, bytes);
          final image = events.whereType<ImageEvent>().single;
          expect(image.part.resource, "res-$name");
          expect(image.part.mimeType, type);
          expect(events.indexOf(image),
              lessThan(events.indexWhere((e) => e is ToolResultEvent)));
          final result = events.whereType<ToolResultEvent>().single.result;
          expect(result.returnCode, 0);
          expect(result.output, contains("attached"));
        }
      });

      test("is known by its bytes, not its name", () async {
        final events = await read("shot.txt", png);
        expect(events.whereType<ImageEvent>().single.part.mimeType, "image/png");
        final named = await read("notes.png", Uint8List.fromList(utf8.encode("hi")));
        expect(named.whereType<ImageEvent>(), isEmpty);
        expect(named.whereType<ToolResultEvent>().single.result.output, contains("hi"));
      });

      test("fails saying why where the model cannot take it", () async {
        Future<String?> refused(String name, Uint8List bytes,
            {bool seesImages = true, bool seesPdfs = true, bool canSave = true}) async {
          final events = await read(name, bytes,
              seesImages: seesImages, seesPdfs: seesPdfs, canSave: canSave);
          expect(events.whereType<ImageEvent>(), isEmpty);
          return events.whereType<ToolResultEvent>().single.result.exceptionInfo;
        }

        expect(await refused("spec.pdf", pdf, seesPdfs: false), contains("pdftotext"));
        expect(await refused("shot.png", png, seesImages: false), contains("cannot view"));
        expect(await refused("shot.png", png, canSave: false), contains("cannot view"));
        final huge = Uint8List(4000000)..setAll(0, png);
        expect(await refused("huge.png", huge), contains("Downscale"));
      });
    });

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

    test("a read pulls in the subdirectory's AGENTS.md where the gate is on",
        () async {
      // On: the read carries the directory's rules with the file.
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

      // Off: the file alone, no rules ride in.
      final gated = FakeLlmClient([
        [readCall("sub/notes.txt")],
        [finish],
      ]);
      final agentOff =
          agentOver(gated, memory: const MemorySettings(nested: false));
      Directory(p.join(agentOff.workspace, "sub")).createSync(recursive: true);
      File(p.join(agentOff.workspace, "sub", "notes.txt")).writeAsStringSync("hi");
      File(p.join(agentOff.workspace, "sub", "AGENTS.md"))
          .writeAsStringSync("sub rules");

      final offEvents = await agentOff.run(userMessage("read it")).toList();

      final offResult = offEvents.whereType<ToolResultEvent>().single.result;
      expect(offResult.output, contains("hi"));
      expect(offResult.output, isNot(contains("sub rules")));
    });

    test("a read outside the workspaces brings the repository's AGENTS.md",
        () async {
      final client = FakeLlmClient([
        [readCall("PLACEHOLDER")],
        [finish],
      ]);
      final agent = agentOver(client, memory: const MemorySettings(nested: true));
      final repo = p.join(p.dirname(agent.projectWorkspace), "repo");
      Directory(p.join(repo, "src")).createSync(recursive: true);
      File(p.join(repo, "src", "main.c")).writeAsStringSync("int main;");
      File(p.join(repo, "AGENTS.md")).writeAsStringSync("repo rules");
      client.turns[0] = [readCall(p.join(repo, "src", "main.c"))];

      final events = await agent.run(userMessage("read it")).toList();

      expect(events.whereType<ToolResultEvent>().single.result.output,
          contains("repo rules"));
      expect(events.whereType<InstructionsReadEvent>().single.files.single.path,
          p.join(repo, "AGENTS.md"));
    });

    test("reading an AGENTS.md does not append it to itself", () async {
      final client = FakeLlmClient([
        [readCall("sub/AGENTS.md")],
        [finish],
      ]);
      final agent = agentOver(client, memory: const MemorySettings(nested: true));
      Directory(p.join(agent.workspace, "sub")).createSync(recursive: true);
      File(p.join(agent.workspace, "sub", "AGENTS.md"))
          .writeAsStringSync("sub rules");

      final events = await agent.run(userMessage("read it")).toList();

      final output = events.whereType<ToolResultEvent>().single.result.output;
      expect("sub rules".allMatches(output), hasLength(1));
      expect(events.whereType<InstructionsReadEvent>(), isEmpty);
    });

    test("edit and write refuse an existing file that was not read", () async {
      final client = FakeLlmClient([
        [editCall("a.txt", "one", "two")],
        [writeCall("a.txt", "over", id: "write-1")],
        [writeCall("new.txt", "fresh", id: "write-2")],
        [finish],
      ]);
      final agent = agentOver(client);
      File(p.join(agent.workspace, "a.txt")).writeAsStringSync("one");

      final events = await agent.run(userMessage("change it")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[0].result.returnCode, isNot(0));
      expect(results[0].result.exceptionInfo, contains("has not been read"));
      expect(results[1].result.exceptionInfo, contains("has not been read"));
      // A new file needs no read.
      expect(results[2].result.returnCode, 0);
      expect(File(p.join(agent.workspace, "a.txt")).readAsStringSync(), "one");
    });

    test("an edit after a read lands; one after the file changed is refused",
        () async {
      late String file;
      final client = FakeLlmClient([
        [readCall("a.txt")],
        [editCall("a.txt", "one", "two")],
        [editCall("a.txt", "two", "three", id: "edit-2")],
        [bashCall("change it")],
        [editCall("a.txt", "two", "four", id: "edit-3")],
        [finish],
      ]);
      final agent = agentOver(client, respond: (_) {
        File(file).writeAsStringSync("someone else's text");
        return ok("");
      });
      file = p.join(agent.workspace, "a.txt");
      File(file).writeAsStringSync("one");

      final events = await agent.run(userMessage("change it")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[1].result.returnCode, 0);
      // Its own edit counts as seen: the second needs no read between.
      expect(results[2].result.returnCode, 0);
      expect(results[4].result.exceptionInfo, contains("has changed"));
      expect(File(file).readAsStringSync(), "someone else's text");
    });

    test("the edit tool replaces once, across all, or refuses", () async {
      // A unique string is the ordinary case.
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

      // Not unique: refused with the count named, not applied at a guess.
      final ambiguous = FakeLlmClient([
        [writeCall("test.txt", "a a a")],
        [editCall("test.txt", "a", "b")],
        [finish],
      ]);
      final refused =
          await agentOver(ambiguous).run(userMessage("write and edit")).toList();

      final refusedResults = refused.whereType<ToolResultEvent>().toList();
      expect(refusedResults[1].result.returnCode, -1);
      expect(refusedResults[1].result.exceptionInfo, contains("3 times"));

      // replace_all: every occurrence.
      final all = FakeLlmClient([
        [writeCall("test.txt", "a a a")],
        [editCall("test.txt", "a", "b", replaceAll: true)],
        [readCall("test.txt")],
        [finish],
      ]);
      final replaced =
          await agentOver(all).run(userMessage("write, edit, read")).toList();

      final replacedResults = replaced.whereType<ToolResultEvent>().toList();
      expect(replacedResults[1].result.returnCode, 0);
      expect(replacedResults[1].result.output, contains("replaced 3"));
      expect(replacedResults[2].result.output, contains("b b b"));
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

    test("a tool that throws is a failed result, not a thrown one", () async {
      // Reading a binary: refused with what it found, killing no stream.
      final read = FakeLlmClient([
        [readCall("data.bin")],
        [finish],
      ]);
      final reads = agentOver(read);
      File(p.join(reads.workspace, "data.bin")).writeAsBytesSync([0xFF, 0xFE, 0x00, 0x80]);

      final readEvents = await reads.run(userMessage("read it")).toList();

      expect(readEvents.whereType<ErrorEvent>(), isEmpty);
      final readResult = readEvents.whereType<ToolResultEvent>().single.result;
      expect(readResult.returnCode, -1);
      expect(readResult.exceptionInfo, contains("binary"));
      expect(readResult.exceptionInfo, contains("data.bin"));

      // Writing over a file: the throw is the failed result.
      final write = FakeLlmClient([
        [writeCall("blocked/hello.txt", "hi")],
        [finish],
      ]);
      final writes = agentOver(write);
      File(p.join(writes.workspace, "blocked")).writeAsStringSync("a file");

      final writeEvents = await writes.run(userMessage("write it")).toList();

      expect(writeEvents.whereType<ErrorEvent>(), isEmpty);
      final writeResult = writeEvents.whereType<ToolResultEvent>().single.result;
      expect(writeResult.returnCode, -1);
      expect(writeResult.exceptionInfo, isNotEmpty);

      // Editing one: same again.
      final edit = FakeLlmClient([
        [editCall("image.png", "a", "b")],
        [finish],
      ]);
      final edits = agentOver(edit);
      File(p.join(edits.workspace, "image.png")).writeAsBytesSync([0x00, 0x01, 0x02]);

      final editEvents = await edits.run(userMessage("edit it")).toList();

      expect(editEvents.whereType<ErrorEvent>(), isEmpty);
      final editResult = editEvents.whereType<ToolResultEvent>().single.result;
      expect(editResult.returnCode, -1);
      expect(editResult.exceptionInfo, isNotEmpty);
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

    test("an absolute path into the workspace runs without asking", () async {
      final turns = <List<LlmChunk>>[];
      final agent = agentOver(FakeLlmClient(turns), approveMode: ApproveMode.ask);
      final inside = p.join(agent.workspace, "inside.txt");
      turns
        ..add([writeCall(inside, "in")])
        ..add([finish]);
      final events = await agent.run(userMessage("write inside")).toList();

      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(File(inside).readAsStringSync(), "in");
    });
  });

  group("a path past the workspaces", () {
    /// The file tools reach the machine itself, so in ask mode they are
    /// offered to the user before they run. The script is built around the
    /// path the agent's own workspaces leave out.
    (BuiltinAgent, String) scriptWritingOutside(FakeLlmClient client,
        {List<ApprovalResponse> approvals = const []}) {
      final agent =
          agentOver(client, approveMode: ApproveMode.ask, approvals: approvals);
      final outside = p.join(p.dirname(agent.projectWorkspace), "outside.txt");
      client.turns
        ..add([writeCall(outside, "there")])
        ..add([finish]);
      return (agent, outside);
    }

    test("is offered to the user before it runs, and the answer rules", () async {
      // Allowed: it writes, having asked.
      final (agent, outside) = scriptWritingOutside(FakeLlmClient([]),
          approvals: [ApprovalResponse.allow]);
      final events = await agent.run(userMessage("write outside")).toList();

      expect(events.whereType<ApprovalRequestEvent>().single.approval.argumentsText,
          outside);
      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("Wrote"));

      // Denied: nothing on disk, and the model told why.
      final (denied, deniedPath) = scriptWritingOutside(FakeLlmClient([]),
          approvals: [ApprovalResponse.deny]);
      final refusal =
          await denied.run(userMessage("write outside")).toList();

      expect(
          refusal.whereType<ApprovalRequestEvent>().single.approval.argumentsText,
          deniedPath);
      final refused = refusal.whereType<ToolResultEvent>().single.result;
      expect(refused.returnCode, -1);
      expect(refused.exceptionInfo, contains("denied"));
      expect(File(deniedPath).existsSync(), isFalse);
    });
  });

  group("the shell a command runs in", () {
    test("the directory a command leaves the shell in is on the result, not "
        "in its output", () async {
      final moved = "/tmp/somewhere/else";
      final client = FakeLlmClient([
        [bashCall("cd somewhere/else")],
        [bashCall("pwd")],
        [finish],
      ]);
      final events = await agentOver(
              client, respond: (c) => ok(c.contains("cd") ? "moved" : "here", cwd: moved))
          .run(userMessage("move and stay")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      // The move is a fact the projection words, so the output stays what the
      // command printed.
      expect(results[0].result.cwd, moved);
      expect(results[1].result.cwd, moved);
      expect(results[0].result.output, "moved");
      expect(results[1].result.output, "here");
    });

    test("and the fact carries into the results of the turn after", () async {
      final moved = "/tmp/somewhere/else";
      final client = FakeLlmClient([
        [bashCall("cd somewhere/else")],
        [bashCall("ls")],
        [finish],
      ]);
      await agentOver(client, respond: (c) => ok("", cwd: moved))
          .run(userMessage("move")).toList();

      final again = FakeLlmClient([
        [bashCall("pwd")],
        [finish],
      ]);
      final events = await agentOver(again, respond: (c) => ok("", cwd: moved))
          .run(userMessage("stay")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.cwd, moved);
      expect(result.output, "");
    });

    test("the model's timeout reaches the shell, capped by the chat's", () async {
      final client = FakeLlmClient([
        [bashCall("a build", extra: {"timeout": 5000})],
        [bashCall("again", extra: {"timeout": 999999999, "restart": true})],
        [finish],
      ]);
      await agentOver(client,
              options: const BuiltinOptions(commandTimeout: Duration(seconds: 60)))
          .run(userMessage("build")).toList();

      expect(shell.timeouts, [const Duration(seconds: 5), const Duration(seconds: 60)]);
      expect(shell.restarts, [false, true]);
      expect(shell.oneShots, [false, false]);
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

    test("what memory_search puts in the result", () async {
      await store.add("the user prefers tabs over spaces");
      await store.add("notes about the weather");

      // What it is about; not what it is not.
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

      // The ids the correction tools take, beside what was found.
      final tabs = (await store.entries())
          .firstWhere((e) => e.text.contains("prefers tabs"));
      final ids = FakeLlmClient([
        [fileCall(memorySearchToolName, {"query": "how does the user like code"})],
        [finish],
      ]);
      final idEvents =
          await agentOver(ids, memoryStore: store).run(userMessage("look it up")).toList();

      expect(idEvents.whereType<ToolResultEvent>().first.result.output,
          contains("[${tabs.id}]"));

      // Nothing matching: said, not an empty string.
      final empty = FakeLlmClient([
        [fileCall(memorySearchToolName, {"query": "completely unrelated words"})],
        [finish],
      ]);
      final emptyEvents =
          await agentOver(empty, memoryStore: store).run(userMessage("look it up")).toList();

      expect(emptyEvents.whereType<ToolResultEvent>().first.result.returnCode, 0);
      expect(emptyEvents.whereType<ToolResultEvent>().first.result.output,
          contains("No memories match"));
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

    test("memory_update on a deleted id fails and writes nothing", () async {
      final entry = await store.add("a fact that is wrong");
      await store.delete(entry.id);

      final client = FakeLlmClient([
        [fileCall(memoryUpdateToolName, {"id": entry.id, "text": "revived"})],
        [finish],
      ]);
      final events =
          await agentOver(client, memoryStore: store).run(userMessage("update")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, isNot(0));
      expect(result.exceptionInfo, contains("no memory with id ${entry.id}"));
      expect(await store.entries(), isEmpty);
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
  });

  group("the static gate", () {
    /// A helper the agent reads through `sandboxFor`, so the gate is on. The
    /// fake shell never runs anything confined; these tests are about what
    /// the agent refuses and what it hands the shell, not what the kernel
    /// does — the landlock tests answer for that.
    final helper = _StubSandboxHelper();

    test("a command the gate escalates is not run and says why", () async {
      // Unmodelable: no tool of the shell can carry it.
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      final events = await agentOver(client, sandboxHelper: helper)
          .run(userMessage("go"))
          .toList();
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results, isNotEmpty);
      final text = results
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text.toLowerCase(), contains("cannot be checked as one piece"));
      expect(shell.ran, isEmpty,
          reason: "an unmodelable command never reaches the shell");

      // An assignment that rewrites where writes land: refused by name.
      final assignment = FakeLlmClient([
        [bashCall("HOME=/tmp/evil git commit")], [finish],
      ]);
      final assignmentEvents = await agentOver(assignment, sandboxHelper: helper)
          .run(userMessage("go"))
          .toList();
      expect(
          assignmentEvents
              .whereType<ToolResultEvent>()
              .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
              .join(),
          contains("HOME"));
      expect(shell.ran, isEmpty);
    });

    test("a modeled command runs and reaches the shell sandboxed", () async {
      final client = FakeLlmClient([
        [bashCall("echo hi")], [finish],
      ]);
      await agentOver(client, sandboxHelper: helper).run(userMessage("go")).toList();
      expect(shell.ran, ["echo hi"]);
      expect(shell.sandboxes.single, isNotNull);
      expect(shell.sandboxes.single!.workspace, isNotEmpty);
    });

    test("with no sandbox behind it, the gate is off", () async {
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      await agentOver(client).run(userMessage("go")).toList();
      // No sandbox means no parse to trust and nothing to enforce with: the
      // command runs, and the approval regime is what answered for it.
      expect(shell.ran, hasLength(1));
    });

    test("in auto mode the parse holds only where nobody decided", () async {
      // The classifier asks: the banner is the decision, as in ask mode.
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      await agentOver(client,
              sandboxHelper: _StubSandboxHelper(),
              approveMode: ApproveMode.auto,
              classifier: FakeClassifier(decision: PermissionDecision.ask),
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run(userMessage("go"))
          .toList();

      expect(shell.ran, hasLength(1),
          reason: "the banner is the decision, in auto mode as in ask");

      // The classifier allows: no human read the text, so the gate's refusal
      // is what says why.
      final allowed = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      final events = await agentOver(allowed,
              sandboxHelper: helper,
              approveMode: ApproveMode.auto,
              classifier: FakeClassifier(decision: PermissionDecision.allow))
          .run(userMessage("go"))
          .toList();
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text.toLowerCase(), contains("cannot be checked as one piece"));
      expect(shell.ran, isEmpty);
    });
  });

  group("the plan tools", () {
    /// The agent under test plus its workspace path: the tests here read and
    /// seed `PLAN.md` through it, so a local holds both instead of each test
    /// carrying the pair.
    (BuiltinAgent, String) planAgent(FakeLlmClient client, {List<String?>? answers}) {
      final agent = agentOver(client, answers: answers);
      return (agent, agent.workspace);
    }

    test("plan_add files the task, under the section it names", () async {
      // Default section: Tasks, with the counts and the session message.
      final client = FakeLlmClient([
        [fileCall(planAddToolName, {"task": "add parser", "details": "Parse the header in `parse.dart`."})],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client);
      final events = await agent.run(userMessage("plan it")).toList();

      final plan = File(p.join(workspace, "PLAN.md")).readAsStringSync();
      expect(plan, contains("- [ ] add parser\n  Parse the header in `parse.dart`."));
      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("add parser"));
      expect(client.sent[1].firstWhere((m) => m.toolCallId == "file-1").text,
          contains("add parser"));

      // A named section, created when it does not exist.
      final sectioned = FakeLlmClient([
        [fileCall(planAddToolName, {"task": "clone", "section": "Setup", "details": "Clone it."})],
        [finish],
      ]);
      final (sectionedAgent, sectionedWorkspace) = planAgent(sectioned);
      await sectionedAgent.run(userMessage("plan it")).toList();

      final setupPlan =
          File(p.join(sectionedWorkspace, "PLAN.md")).readAsStringSync();
      final setup = setupPlan.indexOf("## Setup");
      expect(setup, greaterThanOrEqualTo(0));
      expect(setupPlan.indexOf("- [ ] clone"), greaterThan(setup));

      // No details: refused, and nothing written.
      final bare = FakeLlmClient([
        [fileCall(planAddToolName, {"task": "vague"})],
        [finish],
      ]);
      final (bareAgent, bareWorkspace) = planAgent(bare);
      final bareEvents = await bareAgent.run(userMessage("plan it")).toList();
      final refused = bareEvents.whereType<ToolResultEvent>().single.result;
      expect(refused.returnCode, -1);
      expect(refused.exceptionInfo, contains("details"));
      expect(File(p.join(bareWorkspace, "PLAN.md")).existsSync(), isFalse);
    });

    test("plan_next takes the first pending task", () async {
      // Pending work: marked in progress, numbered for the model.
      final client = FakeLlmClient([
        [fileCall(planNextToolName, {}, id: "n1")],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client);
      File(p.join(workspace, "PLAN.md")).writeAsStringSync(
          "# Plan\n\n## Tasks\n\n- [ ] one\n  How one is done.\n- [ ] two\n");
      final events = await agent.run(userMessage("go")).toList();

      expect(File(p.join(workspace, "PLAN.md")).readAsStringSync(),
          contains("- [~] one"));
      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.output, "Task 1 of 2: one\n\nHow one is done.");

      // Nothing pending left.
      final exhausted = FakeLlmClient([
        [fileCall(planNextToolName, {}, id: "n2")],
        [finish],
      ]);
      final (done, doneWorkspace) = planAgent(exhausted);
      File(p.join(doneWorkspace, "PLAN.md")).writeAsStringSync("- [x] one\n");
      final doneEvents = await done.run(userMessage("go")).toList();

      expect(doneEvents.whereType<ToolResultEvent>().single.result.output,
          "All tasks done.");
    });

    test("plan_done finds the task by number or text, and refuses an ambiguous one",
        () async {
      // By number.
      final client = FakeLlmClient([
        [fileCall(planDoneToolName, {"task": "2"})],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client);
      File(p.join(workspace, "PLAN.md")).writeAsStringSync("- [ ] one\n- [ ] two\n");
      final events = await agent.run(userMessage("go")).toList();

      expect(File(p.join(workspace, "PLAN.md")).readAsStringSync(),
          contains("- [x] two"));
      expect(events.whereType<ToolResultEvent>().single.result.output,
          contains("1 of 2 tasks done"));

      // By text prefix.
      final byText = FakeLlmClient([
        [fileCall(planDoneToolName, {"task": "read"})],
        [finish],
      ]);
      final (text, textWorkspace) = planAgent(byText);
      File(p.join(textWorkspace, "PLAN.md"))
          .writeAsStringSync("- [ ] read the code\n- [ ] add parser\n");
      await text.run(userMessage("go")).toList();

      expect(File(p.join(textWorkspace, "PLAN.md")).readAsStringSync(),
          contains("- [x] read the code"));

      // Ambiguous: refused rather than guessed.
      final ambiguous = FakeLlmClient([
        [fileCall(planDoneToolName, {"task": "wri"})],
        [finish],
      ]);
      final (ref, refWorkspace) = planAgent(ambiguous);
      File(p.join(refWorkspace, "PLAN.md"))
          .writeAsStringSync("- [ ] write tests\n- [ ] write docs\n");
      final refEvents = await ref.run(userMessage("go")).toList();

      final result = refEvents.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("more than one task"));
      expect(File(p.join(refWorkspace, "PLAN.md")).readAsStringSync(),
          isNot(contains("[x]")));
    });

    test("plan tools without a plan say so and point at plan_add", () async {
      final client = FakeLlmClient([
        [fileCall(planNextToolName, {}, id: "n3")],
        [fileCall(planDoneToolName, {"task": "1"})],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client);
      final events = await agent.run(userMessage("go")).toList();

      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[0].result.output, contains(planAddToolName));
      expect(results[1].result.returnCode, -1);
      expect(File(p.join(workspace, "PLAN.md")).existsSync(), isFalse);
    });

    test("present_plan publishes nothing and asks", () async {
      final client = FakeLlmClient([
        [fileCall(presentPlanToolName, {"title": "The work"}, id: "pp-1")],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client, answers: ["go"]);
      File(p.join(workspace, "PLAN.md")).writeAsStringSync("- [ ] one\n- [ ] two\n");
      final events = await agent.run(userMessage("present it")).toList();

      expect(events.whereType<ArtifactEvent>(), isEmpty);

      final request = events.whereType<QuestionRequestEvent>().single.request;
      expect(request.questions.single.question, contains("The work"));
      expect(request.questions.single.options.map((o) => o.answer),
          ["go"]);

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("Approved"));
      // The verdict is what the session hands back, so a reload words it
      // the same way.
      expect(client.sent[1].firstWhere((m) => m.toolCallId == "pp-1").text,
          contains("Approved"));
    });

    test("a request for changes tells the model to revise, not to start", () async {
      final client = FakeLlmClient([
        [fileCall(presentPlanToolName, {}, id: "pp-3")],
        [finish],
      ]);
      final (agent, workspace) = planAgent(client, answers: ["merge tasks 1 and 2"]);
      File(p.join(workspace, "PLAN.md")).writeAsStringSync("- [ ] one\n");
      final events = await agent.run(userMessage("present it")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.output, contains("Do not start executing"));
      expect(result.output, contains("present it again"));

      // The unanswered arm: the turn stops rather than starting the work.
      final unanswered = FakeLlmClient([
        [fileCall(presentPlanToolName, {}, id: "pp-4")],
        [finish],
      ]);
      final (held, heldWorkspace) = planAgent(unanswered);
      File(p.join(heldWorkspace, "PLAN.md")).writeAsStringSync("- [ ] one\n");
      final heldEvents = await held.run(userMessage("present it")).toList();

      expect(heldEvents.whereType<ToolResultEvent>().single.result.output,
          contains("Finish the turn"));
    });

    test("present_plan with nothing to show is refused", () async {
      final client = FakeLlmClient([
        [fileCall(presentPlanToolName, {}, id: "pp-5")],
        [finish],
      ]);
      final (agent, _) = planAgent(client);
      final events = await agent.run(userMessage("present it")).toList();

      expect(events.whereType<QuestionRequestEvent>(), isEmpty);
      expect(events.whereType<ToolResultEvent>().single.result.returnCode, -1);
      expect(events.whereType<ToolResultEvent>().single.result.exceptionInfo,
          contains(planAddToolName));
    });

    test("present_plan rides ask alone, not the artifact's publish path", () async {
      // No saveArtifact: the turn loses the artifact tool and keeps
      // present_plan, which publishes nothing, and the plan trio, which
      // rides the floor like the file tools do.
      final client = FakeLlmClient([
        [saidOnly("nothing to run")],
      ]);
      await agentOver(client).run(userMessage("hi")).toList();
      final tools = client.calls.single.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(
          [planAddToolName, planNextToolName, planDoneToolName, presentPlanToolName]));
      expect(tools, isNot(contains(artifactToolName)));
    });
  });
}
/// A sandbox helper that builds a prefix, so the agent's gate and the shell's
/// sandbox plumbing run without a kernel in the loop. The prefix is the
/// shape the real helper's is; what runs it is the test's business.
class _StubSandboxHelper implements SandboxHelper {
  @override
  Future<List<String>?> prefixFor(CommandSandbox sandbox) async =>
      ["/bin/entoli-landlock", "exec", "--workspace", sandbox.workspace, "--"];

  @override
  String? reportPathFor(CommandSandbox sandbox) => null;

  @override
  String? get reportShimPath => null;
}
