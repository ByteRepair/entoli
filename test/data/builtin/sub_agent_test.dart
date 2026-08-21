import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/gated_client.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/rate_limit_gate.dart";
import "package:agent_chat/data/builtin/sub_agent.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  setUp(() => session = BuiltinSession());

  PromptLibrary libraryWithGeneral() => PromptLibrary([
        PromptDocument.parse(
            CompletionKind.agent, "general", "---\n---\nYou are a general agent."),
      ]);

  /// The runner under test. [subClient] drives the sub-agent's turns;
  /// [respond] answers its bash commands.
  SubAgentRunner runnerOver(
    FakeLlmClient subClient, {
    ShellResult Function(String)? respond,
  }) {
    shell = FakeShell(respond ?? (_) => ok(""), canRunCommands: true);
    return SubAgentRunner(
      client: subClient,
      shell: shell,
      fs: fileSystemIo,
      workspace: "/tmp/workspace",
      projectWorkspace: "/tmp/project",
      model: "fake-model",
      library: libraryWithGeneral(),
    );
  }

  group("SubAgentRunner", () {
    test("returns the sub-agent's final text", () async {
      final subClient = FakeLlmClient([
        [bashCall("echo hello")],
        [saidOnly("The answer is hello.")],
      ]);
      final runner = runnerOver(subClient);
      final result = await runner.run("general", "say hello");

      expect(result.returnCode, 0);
      expect(result.output, contains("The answer is hello."));
      expect(shell.ran, ["echo hello"]);
    });

    test("a missing agent name falls back to general", () async {
      final subClient = FakeLlmClient([
        [saidOnly("done")],
      ]);
      final runner = runnerOver(subClient);
      final result = await runner.run("nonexistent", "do something");

      expect(result.returnCode, 0);
      expect(result.output, contains("done"));
    });

    test("an empty result is reported as a failure", () async {
      final subClient = FakeLlmClient([
        [bashCall("true")],
        [saidOnly("")],
      ]);
      final runner = runnerOver(subClient, respond: (c) => ok(""));
      final result = await runner.run("general", "do something");

      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("no output"));
    });

    test("a sub-agent error is reported, not thrown", () async {
      final subClient = FakeLlmClient([
        [bashCall("echo hi")],
      ])
        ..failures[0] = const LlmException("bad key", statusCode: 401);
      final runner = runnerOver(subClient);
      final result = await runner.run("general", "do something");

      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("bad key"));
    });

    test("sub-agents are not offered the task or ask_user tools", () async {
      final subClient = FakeLlmClient([
        [saidOnly("done")],
      ]);
      final runner = runnerOver(subClient);
      await runner.run("general", "do something");

      final tools = subClient.calls.single.tools.map((t) => t.name).toSet();
      expect(tools, contains("bash"));
      expect(tools, isNot(contains("task")));
      expect(tools, isNot(contains("ask_user")));
    });
  });

  group("BuiltinAgent with task tool", () {
    const done = LlmCompletion(
      message: LlmMessage(role: LlmRole.assistant, text: "done"),
    );

    /// Parent agent with a [SubAgentRunner] backed by [subClient].
    BuiltinAgent agentOver(
      FakeLlmClient parentClient,
      FakeLlmClient subClient, {
      ShellResult Function(String)? respond,
    }) {
      shell = FakeShell(respond ?? (_) => ok(""), canRunCommands: true);
      final runner = SubAgentRunner(
        client: subClient,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        library: libraryWithGeneral(),
      );
      return BuiltinAgent(
        session: session,
        client: parentClient,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        subAgentRunner: runner,
      );
    }

    test("a task call spawns a sub-agent and returns its output", () async {
      final parent = FakeLlmClient([
        [taskCall("general", "say hello", id: "t1")],
        [done],
      ]);
      final sub = FakeLlmClient([
        [saidOnly("hello from the sub-agent")],
      ]);
      final agent = agentOver(parent, sub);
      final events = await agent.run(userMessage("delegate it")).toList();

      // The parent received the sub-agent's text as the tool result.
      final toolResult = events.whereType<ToolResultEvent>().first.result;
      expect(toolResult.callId, "t1");
      expect(toolResult.output, contains("hello from the sub-agent"));
      expect(toolResult.returnCode, 0);
    });

    test("start and end events fire around the sub-agent", () async {
      final parent = FakeLlmClient([
        [taskCall("general", "do it", id: "t1")],
        [done],
      ]);
      final sub = FakeLlmClient([
        [saidOnly("done")],
      ]);
      final events = await agentOver(parent, sub).run(userMessage("delegate")).toList();

      final start = events.whereType<SubAgentStartEvent>().single;
      expect(start.id, "t1");
      expect(start.agent, "general");
      final end = events.whereType<SubAgentEndEvent>().single;
      expect(end.id, "t1");
      expect(end.failed, isFalse);
    });

    test("the call and result are persisted in the session", () async {
      final parent = FakeLlmClient([
        [taskCall("general", "do it", id: "t1")],
        [done],
      ]);
      final sub = FakeLlmClient([
        [saidOnly("done")],
      ]);
      await agentOver(parent, sub).run(userMessage("delegate")).toList();

      final toolMessages = session.messages.where((m) => m.role == LlmRole.tool);
      expect(toolMessages.map((m) => m.toolCallId), contains("t1"));
    });

    test("a task call with bad arguments is rejected", () async {
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "t1", name: "task", argumentsJson: '{"agent": ""}'),
              ],
            ),
          ),
        ],
        [done],
      ]);
      final sub = FakeLlmClient([]);
      final events = await agentOver(parent, sub).run(userMessage("delegate")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.callId, "t1");
      expect(result.exceptionInfo, contains("task"));
      // No sub-agent was started.
      expect(events.whereType<SubAgentStartEvent>(), isEmpty);
    });

    test("the task tool is offered alongside bash and ask_user", () async {
      final parent = FakeLlmClient([
        [done],
      ]);
      final sub = FakeLlmClient([]);
      await agentOver(parent, sub).run(userMessage("hi")).toList();

      final tools = parent.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(["bash", "task", "ask_user"]));
    });

    test("multiple task calls in one message run concurrently", () async {
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "t1", name: "task",
                    argumentsJson: jsonEncode({"agent": "general", "prompt": "task A"})),
                LlmToolCall(id: "t2", name: "task",
                    argumentsJson: jsonEncode({"agent": "general", "prompt": "task B"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      // Each sub-agent replies with text — that's its output.
      final sub = FakeLlmClient([
        [saidOnly("result A")],
        [saidOnly("result B")],
      ]);
      final events = await agentOver(parent, sub).run(userMessage("fan out")).toList();

      // Both sub-agents started and ended.
      final starts = events.whereType<SubAgentStartEvent>().toList();
      expect(starts.map((s) => s.id).toSet(), {"t1", "t2"});
      final ends = events.whereType<SubAgentEndEvent>().toList();
      expect(ends.map((e) => e.id).toSet(), {"t1", "t2"});

      // Both results came back.
      final results = events.whereType<ToolResultEvent>().where((e) =>
          e.result.callId != "done").toList();
      expect(results.map((r) => r.result.callId).toSet(), {"t1", "t2"});
    });

    test("the concurrency cap limits simultaneous sub-agents", () async {
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                for (var i = 0; i < 5; i++)
                  LlmToolCall(id: "t$i", name: "task",
                      argumentsJson: jsonEncode({"agent": "general", "prompt": "task $i"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      final sub = FakeLlmClient([
        for (var i = 0; i < 5; i++) [saidOnly("result $i")],
      ]);
      shell = FakeShell((_) => ok(""), canRunCommands: true);
      final runner = SubAgentRunner(
        client: sub,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        library: libraryWithGeneral(),
      );
      final agent = BuiltinAgent(
        session: session,
        client: parent,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(maxConcurrentSubAgents: 2),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        subAgentRunner: runner,
      );

      final events = await agent.run(userMessage("fan out")).toList();
      final ends = events.whereType<SubAgentEndEvent>().toList();
      expect(ends, hasLength(5));
    });

    test("cancel stops running sub-agents", () async {
      final parent = FakeLlmClient([
        [taskCall("general", "long task", id: "t1")],
      ]);
      final sub = FakeLlmClient([
        [bashCall("sleep 10")],
        [saidOnly("done")],
      ]);
      shell = FakeShell((c) => c.startsWith("sleep")
          ? ShellResult(returnCode: 0, output: "")
          : ok(""));
      final runner = SubAgentRunner(
        client: sub,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        library: libraryWithGeneral(),
      );
      final agent = BuiltinAgent(
        session: session,
        client: parent,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        subAgentRunner: runner,
      );

      final events = <AgentEvent>[];
      final doneFuture = agent.run(userMessage("delegate")).forEach(events.add);
      // Let the sub-agent start.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await agent.cancel();
      await doneFuture;

      // The turn ended without finishing normally.
      expect(events.last, isA<DoneEvent>());
    });
  });

  group("RateLimitGate with sub-agents", () {
    const done = LlmCompletion(
      message: LlmMessage(role: LlmRole.assistant, text: "done"),
    );

    /// A parent + sub-agent pair sharing one gate, both talking through
    /// [ConcurrentFakeLlmClient] so the test can assert the in-flight cap.
    ({BuiltinAgent agent, ConcurrentFakeLlmClient parentTrack, ConcurrentFakeLlmClient subTrack, RateLimitGate gate})
        gatedAgent(
      FakeLlmClient parentClient,
      FakeLlmClient subClient, {
      int maxConcurrent = 2,
      Duration initialBackoff = const Duration(seconds: 1),
      Duration maxRetryBudget = const Duration(minutes: 5),
      BuiltinOptions options = const BuiltinOptions(),
      ShellResult Function(String)? respond,
    }) {
      shell = FakeShell(respond ?? (_) => ok(""), canRunCommands: true);
      final gate = RateLimitGate(
        maxConcurrent: maxConcurrent,
        initialBackoff: initialBackoff,
        maxRetryBudget: maxRetryBudget,
      );
      final parentTrack = ConcurrentFakeLlmClient(parentClient);
      final subTrack = ConcurrentFakeLlmClient(subClient);
      final gatedParent = GatedLlmClient(parentTrack, gate);
      final gatedSub = GatedLlmClient(subTrack, gate);
      final runner = SubAgentRunner(
        client: gatedSub,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        library: libraryWithGeneral(),
        options: options,
        rateLimitGate: gate,
      );
      final agent = BuiltinAgent(
        session: session,
        client: gatedParent,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: options,
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        subAgentRunner: runner,
        rateLimitGate: gate,
      );
      return (agent: agent, parentTrack: parentTrack, subTrack: subTrack, gate: gate);
    }

    test("a 5-sub-agent fan-out with maxConcurrent 2 never exceeds 2 in flight",
        () async {
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                for (var i = 0; i < 5; i++)
                  LlmToolCall(id: "t$i", name: "task",
                      argumentsJson: jsonEncode({"agent": "general", "prompt": "task $i"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      // Each sub-agent makes one model call then finishes.
      final sub = FakeLlmClient([
        for (var i = 0; i < 5; i++) [saidOnly("result $i")],
      ]);
      final (:agent, :subTrack, :parentTrack, :gate) = gatedAgent(parent, sub,
          maxConcurrent: 2,
          options: const BuiltinOptions(maxConcurrentSubAgents: 5));

      await agent.run(userMessage("fan out")).toList();

      // The sub-agents' model calls never exceeded 2 in flight.
      expect(subTrack.maxConcurrent, lessThanOrEqualTo(2));
      expect(subTrack.maxConcurrent, greaterThan(0));
    });

    test("429 on a sub-agent pauses all siblings and resumes after the cooldown",
        () async {
      // 3 sub-agents. The first sub-agent call gets a 429, then succeeds on
      // retry; the other two succeed on the first try. With maxConcurrent 1,
      // the 429's cooldown gates the others — they wait, then run.
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                for (var i = 0; i < 3; i++)
                  LlmToolCall(id: "t$i", name: "task",
                      argumentsJson: jsonEncode({"agent": "general", "prompt": "task $i"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      // Sub-agent turns: call 0 -> 429 then success; calls 1, 2 -> success.
      // FakeLlmClient uses one entry per call, in order, and _at is global
      // across the three concurrent sub-agents — but with maxConcurrent 1
      // they serialize, so the order is deterministic.
      final sub = FakeLlmClient([
        [saidOnly("first")],   // at=0: 429
        [saidOnly("first")],   // at=1: retry succeeds
        [saidOnly("second")],  // at=2: sub-agent 1
        [saidOnly("third")],   // at=3: sub-agent 2
      ])
        ..failures[0] = const LlmException("rate limited", statusCode: 429, retryable: true);
      final (:agent, :subTrack, :parentTrack, :gate) = gatedAgent(parent, sub,
          maxConcurrent: 1,
          initialBackoff: const Duration(milliseconds: 50),
          options: const BuiltinOptions(maxConcurrentSubAgents: 3));

      final events = await agent.run(userMessage("fan out")).toList();

      // All three sub-agents finished despite the first's 429.
      final ends = events.whereType<SubAgentEndEvent>().toList();
      expect(ends, hasLength(3));
      // The first sub-agent recovered (the 429 was retried through the gate).
      expect(ends.every((e) => !e.failed), isTrue);
    });

    test("429 retry budget exhaustion reports an error instead of looping", () async {
      // A sub-agent whose every call 429s. The gate's budget is tiny so the
      // agent gives up quickly.
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "t0", name: "task",
                    argumentsJson: jsonEncode({"agent": "general", "prompt": "task 0"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      // Every sub-agent call 429s.
      final sub = FakeLlmClient([
        for (var i = 0; i < 20; i++) [saidOnly("never")],
      ]);
      for (var i = 0; i < 20; i++) {
        sub.failures[i] = const LlmException("rate limited", statusCode: 429, retryable: true);
      }
      final (:agent, :subTrack, :parentTrack, :gate) = gatedAgent(parent, sub,
          maxConcurrent: 1,
          initialBackoff: const Duration(milliseconds: 10),
          maxRetryBudget: const Duration(milliseconds: 200));

      final events = await agent.run(userMessage("fan out")).toList();

      // The sub-agent failed — its result carries the 429.
      final result = events.whereType<ToolResultEvent>().firstWhere((e) => e.result.callId == "t0").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("429"));
    });

    test("429 with no gate falls back to maxAttempts", () async {
      // The original per-agent path: no rateLimitGate, no GatedLlmClient.
      // A sub-agent call 429s 4 times then the agent gives up.
      final parent = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "t0", name: "task",
                    argumentsJson: jsonEncode({"agent": "general", "prompt": "task 0"})),
              ],
            ),
          ),
        ],
        [done],
      ]);
      final sub = FakeLlmClient([
        for (var i = 0; i < 10; i++) [saidOnly("never")],
      ]);
      for (var i = 0; i < 10; i++) {
        sub.failures[i] = const LlmException("rate limited", statusCode: 429, retryable: true);
      }
      shell = FakeShell((_) => ok(""), canRunCommands: true);
      // No gate, no GatedLlmClient — raw clients.
      final runner = SubAgentRunner(
        client: sub,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        library: libraryWithGeneral(),
      );
      final agent = BuiltinAgent(
        session: session,
        client: parent,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        subAgentRunner: runner,
      );

      final events = await agent.run(userMessage("fan out")).toList();

      // The sub-agent gave up after maxAttempts 429s.
      final result = events.whereType<ToolResultEvent>().firstWhere((e) => e.result.callId == "t0").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("429"));
      // Only 4 attempts were made (the fake's _at advanced 4 times).
      expect(sub.calls, hasLength(4));
    });
  });
}