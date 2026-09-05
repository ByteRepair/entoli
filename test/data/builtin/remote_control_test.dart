import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/remote_control.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;
  late FakeRemoteControl remote;

  setUp(() {
    session = BuiltinSession();
    shell = FakeShell((_) => ok(""), canRunCommands: true);
    remote = FakeRemoteControl();
  });

  BuiltinAgent agentWith(
    FakeLlmClient client, {
    RemoteControl? remoteControl,
    bool useDefault = true,
  }) =>
      BuiltinAgent(
        session: session,
        client: client,
        shell: shell,
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        remoteControl: useDefault ? (remoteControl ?? remote) : remoteControl,
        saveResource: (filename, bytes) async => "res-1",
      );

  group("BuiltinAgent with remote control", () {
    final finish = saidOnly("done");

    test("screenshot, click and key are offered alongside bash", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client).run(userMessage("hi")).toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, containsAll(["screenshot", "click", "key", "bash"]));
    });

    test("the tools are not offered when unavailable", () async {
      final client = FakeLlmClient([[finish]]);
      remote = FakeRemoteControl(available: false);
      await agentWith(client).run(userMessage("hi")).toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("screenshot")));
      expect(tools, isNot(contains("click")));
      expect(tools, isNot(contains("key")));
    });

    test("the tools are not offered when remote control is null", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, useDefault: false).run(userMessage("hi")).toList();

      final tools = client.calls.first.tools.map((t) => t.name).toSet();
      expect(tools, isNot(contains("screenshot")));
    });

    test("a screenshot call captures and names a resource", () async {
      final client = FakeLlmClient([
        [screenshotCall(id: "s1")],
        [finish],
      ]);
      final events = await agentWith(client).run(userMessage("see")).toList();

      expect(remote.screenshots, hasLength(1));

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "s1").result;
      expect(result.returnCode, 0);
      expect(result.resource, "res-1");
    });

    test("a click call delivers the coordinates and button", () async {
      final client = FakeLlmClient([
        [clickCall(10, 20, 2, id: "c1")],
        [finish],
      ]);
      await agentWith(client).run(userMessage("click")).toList();

      expect(remote.clicks, [(x: 10, y: 20, button: 2)]);
    });

    test("a key call delivers the text", () async {
      final client = FakeLlmClient([
        [keyCall("hello", id: "k1")],
        [finish],
      ]);
      await agentWith(client).run(userMessage("type")).toList();

      expect(remote.keys, ["hello"]);
    });

    test("a click call with bad arguments is rejected", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "c1", name: "click", argumentsJson: "{}"),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentWith(client).run(userMessage("click")).toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "c1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("click"));
      expect(remote.clicks, isEmpty);
    });

    test("a screenshot failure is reported, not thrown", () async {
      final client = FakeLlmClient([
        [screenshotCall(id: "s1")],
        [finish],
      ]);
      remote.screenshotResult = () => throw StateError("no screen");
      final events = await agentWith(client).run(userMessage("see")).toList();

      final result = events.whereType<ToolResultEvent>().firstWhere(
          (e) => e.result.callId == "s1").result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("no screen"));
    });

    test("the screenshot image reaches the model as an attachment", () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      remote.screenshotResult = () => bytes;
      final client = FakeLlmClient([
        [screenshotCall(id: "s1")],
        [finish],
      ]);
      await agentWith(client).run(userMessage("see")).toList();

      final toolMessage = session.messages
          .where((m) => m.role == LlmRole.tool && m.toolCallId == "s1")
          .single;
      expect(toolMessage.attachments, hasLength(1));
      expect(toolMessage.attachments.single.bytes, bytes);
      expect(toolMessage.attachments.single.mimeType, "image/png");
    });
  });
}
