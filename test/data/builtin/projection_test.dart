import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/projection.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  final at = DateTime.utc(2026, 1, 1);
  var next = 0;

  Message said(MessageRole role, List<MessagePart> parts) =>
      Message(id: "m${next++}", role: role, createdAt: at, parts: parts);

  Message asked(String text) => said(MessageRole.user, [MessagePart.text(text: text)]);

  MessagePart call(String id, String name, String arguments, {String? response}) =>
      MessagePart.toolCall(
        toolCall: ToolCall(id: id, name: name, argumentsJson: arguments),
        responseId: response,
      );

  MessagePart ran(String id, String output, {int returnCode = 0}) => MessagePart.toolResult(
      result: ToolResult(callId: id, returnCode: returnCode, output: output));

  /// Nothing in this file is about attachment bytes except the two tests that
  /// pass a loader of their own.
  Future<List<LlmMessage>> project(List<Message> messages, {bool first = true}) =>
      projectionOf(messages, first: first, load: noResources);

  setUp(() => next = 0);

  test("a plain exchange goes back as one message each way", () async {
    final projected = await project([
      asked("what is 2+2?"),
      said(MessageRole.assistant, const [MessagePart.text(text: "four")]),
    ]);

    // The user's turn is worded by [userTurnText] rather than handed back raw:
    // it is what the live turn sent, so it is what a rebuilt session has to
    // send too — the date off the message, and the task framing on the one that
    // opened the chat.
    expect(projected.map((m) => (m.role, m.text)), [
      (LlmRole.user, userTurnText("what is 2+2?", at: at, first: true)),
      (LlmRole.assistant, "four"),
    ]);
  });

  test("only the message that opens the conversation is dressed as a task", () async {
    final projected = await project([
      asked("first"),
      said(MessageRole.assistant, const [MessagePart.text(text: "ok")]),
      asked("second"),
    ]);

    expect(projected.first.text, userTurnText("first", at: at, first: true));
    expect(projected.last.text, userTurnText("second", at: at, first: false));
    expect(projected.last.text, isNot(contains("The user asks")));
  });

  test("a fragment appended to a session already holding the rest opens nothing",
      () async {
    // What `_runBypass` projects: the two messages its turn is writing, onto a
    // session that already has the conversation.
    final projected = await project([asked("later")], first: false);

    expect(projected.single.text, userTurnText("later", at: at, first: false));
  });

  test("thinking travels with the response it belongs to, signature and all", () async {
    final projected = await project([
      asked("go on"),
      said(MessageRole.assistant, const [
        MessagePart.reasoning(text: "weighing it up", durationMs: 20, signature: "sig-1", responseId: "r1"),
        MessagePart.text(text: "here goes", responseId: "r1"),
      ]),
    ]);

    final reply = projected.last;
    expect(reply.reasoning, "weighing it up");
    expect(reply.reasoningSignature, "sig-1");
    expect(reply.text, "here goes");
  });

  test("a turn of several responses goes back as one message each", () async {
    final projected = await project([
      asked("list the files"),
      said(MessageRole.assistant, [
        const MessagePart.reasoning(text: "have a look", responseId: "r1"),
        call("c1", "bash", '{"command":"ls"}', response: "r1"),
        ran("c1", "notes.txt"),
        const MessagePart.text(text: "one file: notes.txt", responseId: "r2"),
      ]),
    ]);

    expect(projected.map((m) => m.role), [
      LlmRole.user,
      LlmRole.assistant,
      LlmRole.tool,
      LlmRole.assistant,
    ]);
    expect(projected[1].reasoning, "have a look");
    expect(projected[1].toolCalls.single.id, "c1");
    expect(projected[2].toolCallId, "c1");
    expect(projected[2].text, contains("notes.txt"));
    // The second response's text is its own message, not folded into the first
    // — the tool result has to sit between them.
    expect(projected[3].text, "one file: notes.txt");
    expect(projected[3].toolCalls, isEmpty);
  });

  test("a result is worded the way the agent worded it when it ran", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"false"}', response: "r1"),
        ran("c1", "nope", returnCode: 1),
      ]),
    ]);

    expect(projected.last.text, observation(returnCode: 1, output: "nope"));
  });

  MessagePart moved(String id, String cwd, {String output = ""}) =>
      MessagePart.toolResult(
        result: ToolResult(
            callId: id, returnCode: 0, output: output, cwd: cwd),
      );

  // The note is derived at wording time from the directory the result carries,
  // so the parts worded live and the same parts worded on a reload say the
  // same thing.
  group("the directory a command leaves the shell in", () {
    test("the turn's opening move is not noted: the model ran the cd itself",
        () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd elsewhere"}', response: "r1"),
          moved("c1", "/elsewhere"),
        ]),
      ]);

      expect(projected.last.text, observation(returnCode: 0, output: ""));
    });

    test("a later move in the same turn is noted, after the observation",
        () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
          call("c2", "bash", '{"command":"cd two"}', response: "r1"),
          moved("c2", "/two"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      expect(tools[0].text, observation(returnCode: 0, output: ""));
      expect(tools[1].text,
          "${observation(returnCode: 0, output: "")}\n\n"
          "Note: your current working directory is now /two.");
    });

    test("a command that stays where it is says nothing new", () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
          call("c2", "bash", '{"command":"ls"}', response: "r1"),
          moved("c2", "/one", output: "here"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      expect(tools[1].text, observation(returnCode: 0, output: "here"));
    });

    test("and the tracking resets at each turn", () async {
      final projected = await project([
        asked("move"),
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
        ]),
        asked("move again"),
        said(MessageRole.assistant, [
          call("c2", "bash", '{"command":"cd two"}', response: "r1"),
          moved("c2", "/two"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      // Each turn's opening move is un-noted, the model having run the `cd`
      // itself, whatever the previous turn left the shell in.
      expect(tools[0].text, observation(returnCode: 0, output: ""));
      expect(tools[1].text, observation(returnCode: 0, output: ""));
    });
  });

  // The answers are the answer; wrapping them as a command's outcome would put
  // the user's own words behind a return code.
  test("an ask_user result goes back as the answers themselves", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("a1", askToolName, '{"questions":[]}', response: "r1"),
        ran("a1", "Which one? Rust"),
      ]),
    ]);

    expect(projected.last.text, "Which one? Rust");
  });

  // A provider that sees a tool call with no result rejects the next turn.
  test("a call whose result never landed is answered anyway", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"sleep 1000"}', response: "r1"),
      ]),
    ]);

    expect(projected.last.role, LlmRole.tool);
    expect(projected.last.toolCallId, "c1");
    expect(projected.last.text, contains("interrupted"));
  });

  // A command's effects outlive the process that ran it, so "not executed"
  // would be a guess — and the wrong one half the time.
  test("an interrupted command is not claimed to have been skipped", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"make install"}', response: "r1"),
      ]),
    ]);

    expect(projected.last.text, contains("may or may not have run"));
    expect(projected.last.text, isNot(contains("not executed")));
  });

  // The answered form is the answers themselves, so the unanswered one is
  // plainly worded too rather than dressed as a command's outcome.
  test("questions the user never saw are answered as questions", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("a1", askToolName, '{"questions":[]}', response: "r1"),
      ]),
    ]);

    expect(projected.last.text, contains("nothing was answered"));
    expect(projected.last.text, isNot(contains("returncode")));
  });

  test("two calls in one response are answered in order, after it", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"ls"}', response: "r1"),
        ran("c1", "one"),
        call("c2", "bash", '{"command":"pwd"}', response: "r1"),
        ran("c2", "two"),
      ]),
    ]);

    expect(projected.map((m) => m.role),
        [LlmRole.assistant, LlmRole.tool, LlmRole.tool]);
    expect(projected.first.toolCalls.map((c) => c.id), ["c1", "c2"]);
    expect(projected[1].toolCallId, "c1");
    expect(projected[2].toolCallId, "c2");
  });

  test("what the user attached is named and sent", () async {
    final projected = await projectionOf([
      said(MessageRole.user, const [
        MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this?"),
      ]),
    ], load: (resource) async => Uint8List.fromList([1, 2, 3]));

    expect(projected.single.text,
        userTurnText("what is this?\n\n(attached: diagram.png)", at: at, first: true));
    expect(projected.single.attachments.single.filename, "diagram.png");
    expect(projected.single.attachments.single.mimeType, "image/png");
    expect(projected.single.attachments.single.bytes, [1, 2, 3]);
  });

  // The bytes are gone, the conversation is not: the model is told a file was
  // attached and asked to carry on without it.
  test("an attachment whose resource has gone is left named", () async {
    final projected = await project([
      said(MessageRole.user, const [
        MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this?"),
      ]),
    ]);

    expect(projected.single.text, contains("(attached: diagram.png)"));
    expect(projected.single.attachments, isEmpty);
  });

  test("a screenshot result is read back and attached to its tool message", () async {
    final projected = await projectionOf([
      asked("see the screen"),
      said(MessageRole.assistant, [
        call("s1", "screenshot", "{}", response: "r1"),
        MessagePart.toolResult(
            result: ToolResult(callId: "s1", returnCode: 0, output: "", resource: "shot-1")),
      ]),
    ], load: (resource) async => Uint8List.fromList([9, 8, 7]));

    final tool = projected.singleWhere((m) => m.role == LlmRole.tool);
    expect(tool.toolCallId, "s1");
    expect(tool.attachments.single.mimeType, "image/png");
    expect(tool.attachments.single.bytes, [9, 8, 7]);
  });

  test("a screenshot whose resource has gone is left without an image", () async {
    final projected = await project([
      asked("see the screen"),
      said(MessageRole.assistant, [
        call("s1", "screenshot", "{}", response: "r1"),
        MessagePart.toolResult(
            result: ToolResult(callId: "s1", returnCode: 0, output: "", resource: "shot-1")),
      ]),
    ]);

    final tool = projected.singleWhere((m) => m.role == LlmRole.tool);
    expect(tool.attachments, isEmpty);
  });

  test("an error is the turn's own report, so it is not put back", () async {
    final projected = await project([
      asked("go"),
      said(MessageRole.assistant, const [
        MessagePart.text(text: "started", responseId: "r1"),
        MessagePart.error(message: "the provider gave up"),
      ]),
    ]);

    expect(projected.last.text, "started");
    expect(projected.map((m) => m.text).join(), isNot(contains("gave up")));
  });

  // As the assistant rather than as a tool call: the model never chose this,
  // and reading back a call it did not make is a conversation it disagrees
  // with.
  test("a command the user ran reads back as what the app did for them", () async {
    final projected = await project([
      asked("!echo hello"),
      said(MessageRole.assistant, const [
        MessagePart.shellRun(command: "echo hello", returnCode: 0, output: "hello\n"),
      ]),
    ]);

    expect(projected.map((m) => m.role), [LlmRole.user, LlmRole.assistant]);
    expect(projected.last.toolCalls, isEmpty);
    expect(projected.last.text, contains("echo hello"));
    expect(projected.last.text, contains('"returncode": 0'));
  });

  test("a message with nothing in it contributes nothing", () async {
    expect(
        await project([asked("   ".trim()), said(MessageRole.assistant, const [])]),
        isEmpty);
  });
}
