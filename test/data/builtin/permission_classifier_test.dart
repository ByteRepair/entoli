import "package:flutter_test/flutter_test.dart";

import "dart:convert";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/permission_classifier.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "builtin_fakes.dart";

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
    late BuiltinSession session;
    late FakeShell shell;
    late FakeClassifier classifier;

    setUp(() {
      session = BuiltinSession();
      classifier = FakeClassifier();
    });

    final finish = saidOnly("done");
    ShellResult okEmpty(String command) => ok("");

    BuiltinAgent agentWith(
      FakeLlmClient client, {
      List<ApprovalResponse> approvals = const [],
      PermissionDecision Function(String, String)? decide,
    }) {
      shell = FakeShell(okEmpty, canRunCommands: true);
      final allowed = [...approvals];
      if (decide != null) classifier.decide = decide;
      return BuiltinAgent(
        session: session,
        client: client,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
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
      // Only the bash command goes through the classifier — finish is a text
      // reply with no tool call, so it is not classified.
      expect(classifier.classified.length, 1);
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
              approvals: [ApprovalResponse.allow])
          .run("push").toList();

      expect(events.whereType<ApprovalRequestEvent>().length, 1);
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
              approvals: List.filled(4, ApprovalResponse.allow))
          .run("test").toList();

      expect(events.whereType<InfoEvent>().single.message, contains("Auto mode paused"));
      // All four commands got approval banners. The finish is a text reply
      // with no tool call, so it is not classified.
      expect(events.whereType<ApprovalRequestEvent>().length, 4);
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
      shell = FakeShell(okEmpty, canRunCommands: true);
      final agent = BuiltinAgent(
        session: session,
        client: client,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.auto,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
      );
      final events = await agent.run("list").toList();

      // Only the bash command asks — finish is a text reply with no tool call.
      expect(events.whereType<ApprovalRequestEvent>().length, 1);
    });

    test("webfetch goes through the classifier in auto mode", () async {
      final client = FakeLlmClient([
        [fetchCall("https://example.com")],
        [finish],
      ]);
      final web = FakeWebSearch(fetchResult: (_) =>
          const ShellResult(returnCode: 0, output: "page"));
      shell = FakeShell(okEmpty, canRunCommands: true);
      classifier.decide = (_, _) => PermissionDecision.deny;
      final agent = BuiltinAgent(
        session: session,
        client: client,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
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