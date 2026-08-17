import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/domain/web_search.dart";

import "builtin_fakes.dart";

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
      await agentWith(client).run("hi").toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(["websearch", "webfetch", "bash"]));
    });

    test("websearch/webfetch are not offered when unavailable", () async {
      final client = FakeLlmClient([[finish]]);
      web = FakeWebSearch(available: false);
      await agentWith(client).run("hi").toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("websearch")));
      expect(tools, isNot(contains("webfetch")));
    });

    test("websearch/webfetch are not offered when webSearch is null", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, useDefaultWeb: false).run("hi").toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("websearch")));
      expect(tools, isNot(contains("webfetch")));
    });

    test("a websearch call runs and returns results", () async {
      final client = FakeLlmClient([
        [searchCall("flutter dart", id: "s1")],
        [finish],
      ]);
      web.searchResult = (q) => const ShellResult(
          returnCode: 0,
          output: "1. Flutter\n   https://flutter.dev\n   A framework.");
      final events = await agentWith(client).run("search").toList();

      expect(web.searched, ["flutter dart"]);

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "s1").result;
      expect(result.returnCode, 0);
      expect(result.output, contains("Flutter"));
      expect(result.output, contains("https://flutter.dev"));
    });

    test("a webfetch call runs and returns content", () async {
      final client = FakeLlmClient([
        [fetchCall("https://example.com", id: "f1")],
        [finish],
      ]);
      web.fetchResult = (url) => const ShellResult(
          returnCode: 0, output: "Example Domain");
      final events = await agentWith(client).run("fetch").toList();

      expect(web.fetched, ["https://example.com"]);

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "f1").result;
      expect(result.returnCode, 0);
      expect(result.output, contains("Example Domain"));
    });

    test("a websearch call with bad arguments is rejected", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "s1", name: "websearch", argumentsJson: '{"query": ""}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentWith(client).run("search").toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "s1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("websearch"));
      expect(web.searched, isEmpty);
    });

    test("a webfetch call with bad arguments is rejected", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "f1", name: "webfetch", argumentsJson: '{}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentWith(client).run("fetch").toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "f1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("webfetch"));
      expect(web.fetched, isEmpty);
    });

    test("the call and result are persisted in the session", () async {
      final client = FakeLlmClient([
        [searchCall("test", id: "s1")],
        [finish],
      ]);
      await agentWith(client).run("search").toList();

      final toolMessages = session.messages.where((m) => m.role == LlmRole.tool);
      expect(toolMessages.map((m) => m.toolCallId), contains("s1"));
    });

    test("a search error is reported, not thrown", () async {
      final client = FakeLlmClient([
        [searchCall("fail", id: "s1")],
        [finish],
      ]);
      web.searchResult = (_) => const ShellResult.failed("Network error.");
      final events = await agentWith(client).run("search").toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "s1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("Network error"));
    });

    test("websearch and webfetch run in the same step", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "s1", name: "websearch",
                    argumentsJson: jsonEncode({"query": "rust"})),
                LlmToolCall(id: "f1", name: "webfetch",
                    argumentsJson: jsonEncode({"url": "https://rust-lang.org"})),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      web.searchResult = (q) => const ShellResult(returnCode: 0, output: "1. Rust\n   https://rust-lang.org");
      web.fetchResult = (url) => const ShellResult(returnCode: 0, output: "Rust programming language");
      final events = await agentWith(client).run("both").toList();

      final results = events.whereType<ToolResultEvent>().where((e) =>
          e.result.callId != "done").toList();
      expect(results.map((r) => r.result.callId).toSet(), {"s1", "f1"});

      // The session has both tool messages in order.
      final toolMessages = session.messages.where((m) => m.role == LlmRole.tool);
      expect(toolMessages.map((m) => m.toolCallId).toList(), ["s1", "f1"]);
    });

    test("a fetch error is reported, not thrown", () async {
      final client = FakeLlmClient([
        [fetchCall("https://broken.example", id: "f1")],
        [finish],
      ]);
      web.fetchResult = (_) => const ShellResult.failed("HTTP 404.");
      final events = await agentWith(client).run("fetch").toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "f1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("HTTP 404"));
    });
  });
}