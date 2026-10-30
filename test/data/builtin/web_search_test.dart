import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/domain/web_search.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";
import "package:agent_chat/data/builtin/builtin_options.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;
  late FakeWebSearch web;

  setUp(() {
    session = BuiltinSession();
    shell = FakeShell((_) => ok(""), canRunCommands: true);
    web = FakeWebSearch();
  });

  BuiltinAgent agentWith(
    FakeLlmClient client, {
    WebSearch? webSearch,
    bool useDefaultWeb = true,
  }) =>
      BuiltinAgent(
        session: session,
        client: client,
        shell: shell,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        webSearch: useDefaultWeb ? (webSearch ?? web) : webSearch,
      );

  group("BuiltinAgent with websearch/webfetch", () {
    final finish = saidOnly("done");

    test("websearch and webfetch are offered alongside bash", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client).run(userMessage("hi")).toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(["websearch", "webfetch", "bash"]));
    });

    test("websearch/webfetch are not offered when nothing is wired", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, useDefaultWeb: false).run(userMessage("hi")).toList();
      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("websearch")));
      expect(tools, isNot(contains("webfetch")));
    });

    LlmCompletion calls(List<(String, String, Map<String, String>)> each) =>
        LlmCompletion(
          message: LlmMessage(
            role: LlmRole.assistant,
            toolCalls: [
              for (final (id, name, args) in each)
                LlmToolCall(id: id, name: name, argumentsJson: jsonEncode(args)),
            ],
          ),
        );

    Future<Map<String, ToolResult>> resultsOf(FakeLlmClient client) async {
      final events = await agentWith(client).run(userMessage("go")).toList();
      return {
        for (final e in events.whereType<ToolResultEvent>()) e.result.callId: e.result,
      };
    }

    test("websearch and webfetch run in one step, answered in order", () async {
      final client = FakeLlmClient([
        [
          calls([
            ("s1", "websearch", {"query": "flutter dart"}),
            ("f1", "webfetch", {"url": "https://example.com"}),
          ])
        ],
        [finish],
      ]);
      web.searchResult = (q) => const ShellResult(
          returnCode: 0,
          output: "1. Flutter\n   https://flutter.dev\n   A framework.");
      web.fetchResult = (url) => const ShellResult(
          returnCode: 0, output: "Example Domain");
      final results = await resultsOf(client);

      expect(web.searched, ["flutter dart"]);
      expect(web.fetched, ["https://example.com"]);
      expect(results["s1"]!.returnCode, 0);
      expect(results["s1"]!.output, contains("https://flutter.dev"));
      expect(results["f1"]!.returnCode, 0);
      expect(results["f1"]!.output, contains("Example Domain"));
      final toolMessages = session.messages.where((m) => m.role == LlmRole.tool);
      expect(toolMessages.map((m) => m.toolCallId).toList(), ["s1", "f1"]);
    });

    test("bad arguments are rejected without reaching the web", () async {
      final client = FakeLlmClient([
        [
          calls([
            ("s1", "websearch", {"query": ""}),
            ("f1", "webfetch", {}),
          ])
        ],
        [finish],
      ]);
      final results = await resultsOf(client);

      expect(results["s1"]!.returnCode, -1);
      expect(results["s1"]!.exceptionInfo, contains("websearch"));
      expect(results["f1"]!.returnCode, -1);
      expect(results["f1"]!.exceptionInfo, contains("webfetch"));
      expect(web.searched, isEmpty);
      expect(web.fetched, isEmpty);
    });

    test("a search or fetch error is reported, not thrown", () async {
      final client = FakeLlmClient([
        [
          calls([
            ("s1", "websearch", {"query": "fail"}),
            ("f1", "webfetch", {"url": "https://broken.example"}),
          ])
        ],
        [finish],
      ]);
      web.searchResult = (_) => const ShellResult.failed("Network error.");
      web.fetchResult = (_) => const ShellResult.failed("HTTP 404.");
      final results = await resultsOf(client);

      expect(results["s1"]!.returnCode, -1);
      expect(results["s1"]!.exceptionInfo, contains("Network error"));
      expect(results["f1"]!.returnCode, -1);
      expect(results["f1"]!.exceptionInfo, contains("HTTP 404"));
    });
  });
}
