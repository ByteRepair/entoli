import "package:flutter_test/flutter_test.dart";

import "dart:convert";

import "package:agent_chat/data/miniswe/llm/llm_client.dart";
import "package:agent_chat/data/miniswe/miniswe_agent.dart";
import "package:agent_chat/data/miniswe/permission_classifier.dart";
import "package:agent_chat/data/miniswe/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "miniswe_fakes.dart";

void main() {
  group("LlmClassifier", () {
    late FakeLlmClient client;

    LlmClassifier classifierOver(List<LlmChunk> reply) {
      client = FakeLlmClient([reply]);
      return LlmClassifier(client: client, model: "classifier-model");
    }

    test("allow runs the command without asking", () async {
      final c = classifierOver([saidOnly("allow")]);
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.allow);
    });

    test("deny refuses the command", () async {
      final c = classifierOver([saidOnly("deny")]);
      final decision = await c.classify("bash", '{"command": "rm -rf /"}', workspace: "/tmp");
      expect(decision, PermissionDecision.deny);
    });

    test("ask escalates to the user", () async {
      final c = classifierOver([saidOnly("ask")]);
      final decision = await c.classify("bash", '{"command": "git push"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });

    test("a reply with extra text still parses the first word", () async {
      final c = classifierOver([saidOnly("allow this command")]);
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.allow);
    });

    test("an unrecognised reply falls back to ask", () async {
      final c = classifierOver([saidOnly("maybe")]);
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });

    test("an empty reply falls back to ask", () async {
      final c = classifierOver([saidOnly("")]);
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });

    test("a failed request falls back to ask", () async {
      client = FakeLlmClient([]);
      client.failures[0] = const LlmException("timeout", retryable: false);
      final c = LlmClassifier(client: client, model: "classifier-model");
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });

    test("webfetch is classified with the URL in the prompt", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("webfetch", '{"url": "https://example.com"}', workspace: "/tmp");
      expect(client.sent.single.last.text, contains("https://example.com"));
    });

    test("bash shows the command plainly, not as JSON", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "echo hi"}', workspace: "/tmp");
      expect(client.sent.single.last.text, contains("echo hi"));
      expect(client.sent.single.last.text, isNot(contains('"command"')));
    });

    test("the system prompt has allow/ask/deny rules", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      final system = client.sent.single.first.text;
      expect(system, contains("allow"));
      expect(system, contains("deny"));
      expect(system, contains("ask"));
    });
  });

  group("NoClassifier", () {
    test("always asks", () async {
      const c = NoClassifier();
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });
  });

  group("auto mode in the agent", () {
    late MinisweSession session;
    late FakeShell shell;
    late FakeClassifier classifier;

    setUp(() {
      session = MinisweSession();
      classifier = FakeClassifier();
    });

    final finish = bashCall("echo $submitMarker", id: "done");
    ShellResult submitted(String command) =>
        command.contains(submitMarker) ? ok("$submitMarker\n") : ok("");

    MinisweAgent agentWith(
      FakeLlmClient client, {
      List<ApprovalResponse> approvals = const [],
      PermissionDecision Function(String, String)? decide,
    }) {
      shell = FakeShell(submitted, canRunCommands: true);
      final allowed = [...approvals];
      if (decide != null) classifier.decide = decide;
      return MinisweAgent(
        session: session,
        client: client,
        shell: shell,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const MinisweOptions(),
        approveMode: ApproveMode.auto,
        classifier: classifier,
        approve: (_) async => allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
        answer: (request) async => request.unanswered,
      );
    }

    test("an allowed command runs without asking", () async {
      final client = FakeLlmClient([
        [bashCall("ls")],
        [finish],
      ]);
      final events = await agentWith(client, decide: (_, _) => PermissionDecision.allow)
          .run("list").toList();

      expect(shell.ran, contains("ls"));
      // Both the command and the finish go through the classifier.
      expect(classifier.classified.length, 2);
      expect(classifier.classified.first.tool, "bash");
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("a denied command is refused, not run", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf /")],
        [finish],
      ]);
      final events = await agentWith(client, decide: (_, _) => PermissionDecision.deny)
          .run("clean").toList();

      expect(shell.ran, isNot(contains("rm -rf /")));
      final result = events.whereType<ToolResultEvent>().first;
      expect(result.result.returnCode, -1);
      expect(result.result.exceptionInfo, contains("Denied"));
    });

    test("an uncertain command escalates to the banner", () async {
      final client = FakeLlmClient([
        [bashCall("git push")],
        [finish],
      ]);
      final events = await agentWith(client,
              decide: (_, _) => PermissionDecision.ask,
              approvals: [ApprovalResponse.allow, ApprovalResponse.allow])
          .run("push").toList();

      expect(events.whereType<ApprovalRequestEvent>().length, 2);
      expect(shell.ran, contains("git push"));
    });

    test("three consecutive asks pause auto mode for the rest of the turn",
        () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "a", name: "bash", argumentsJson: jsonEncode({"command": "a"})),
                LlmToolCall(id: "b", name: "bash", argumentsJson: jsonEncode({"command": "b"})),
                LlmToolCall(id: "c", name: "bash", argumentsJson: jsonEncode({"command": "c"})),
                LlmToolCall(id: "d", name: "bash", argumentsJson: jsonEncode({"command": "d"})),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentWith(client,
              decide: (_, _) => PermissionDecision.ask,
              approvals: List.filled(5, ApprovalResponse.allow))
          .run("test").toList();

      expect(events.whereType<InfoEvent>().single.message, contains("Auto mode paused"));
      // All four commands plus the finish got approval banners.
      expect(events.whereType<ApprovalRequestEvent>().length, 5);
    });

    test("auto paused info does not appear when all commands are allowed",
        () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "a", name: "bash", argumentsJson: jsonEncode({"command": "a"})),
                LlmToolCall(id: "b", name: "bash", argumentsJson: jsonEncode({"command": "b"})),
                LlmToolCall(id: "c", name: "bash", argumentsJson: jsonEncode({"command": "c"})),
                LlmToolCall(id: "d", name: "bash", argumentsJson: jsonEncode({"command": "d"})),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentWith(client, decide: (_, _) => PermissionDecision.allow)
          .run("test").toList();

      expect(events.whereType<InfoEvent>(), isEmpty);
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(shell.ran, containsAll(["a", "b", "c", "d"]));
    });

    test("no classifier falls back to asking for every command", () async {
      final client = FakeLlmClient([
        [bashCall("ls")],
        [finish],
      ]);
      shell = FakeShell(submitted, canRunCommands: true);
      final agent = MinisweAgent(
        session: session,
        client: client,
        shell: shell,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const MinisweOptions(),
        approveMode: ApproveMode.auto,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
      );
      final events = await agent.run("list").toList();

      // Both commands ask, since there is no classifier to allow them.
      expect(events.whereType<ApprovalRequestEvent>().length, 2);
    });

    test("webfetch goes through the classifier in auto mode", () async {
      final client = FakeLlmClient([
        [fetchCall("https://example.com")],
        [finish],
      ]);
      final web = FakeWebSearch(fetchResult: (_) =>
          const ShellResult(returnCode: 0, output: "page"));
      shell = FakeShell(submitted, canRunCommands: true);
      classifier.decide = (_, _) => PermissionDecision.deny;
      final agent = MinisweAgent(
        session: session,
        client: client,
        shell: shell,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const MinisweOptions(),
        approveMode: ApproveMode.auto,
        classifier: classifier,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        webSearch: web,
      );
      final events = await agent.run("fetch").toList();

      expect(web.fetched, isEmpty);
      expect(classifier.classified.first.tool, "webfetch");
      final result = events.whereType<ToolResultEvent>().first;
      expect(result.result.exceptionInfo, contains("Denied"));
    });
  });
}