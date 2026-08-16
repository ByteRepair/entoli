import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/miniswe/llm/llm_client.dart";
import "package:agent_chat/data/miniswe/projection.dart";
import "package:agent_chat/data/miniswe/templates.dart";
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

  setUp(() => next = 0);

  test("a plain exchange goes back as one message each way", () {
    final projected = projectionOf([
      asked("what is 2+2?"),
      said(MessageRole.assistant, const [MessagePart.text(text: "four")]),
    ]);

    expect(projected.map((m) => (m.role, m.text)), [
      (LlmRole.user, "what is 2+2?"),
      (LlmRole.assistant, "four"),
    ]);
  });

  test("thinking travels with the response it belongs to, signature and all", () {
    final projected = projectionOf([
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

  test("a turn of several responses goes back as one message each", () {
    final projected = projectionOf([
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

  test("a result is worded the way the agent worded it when it ran", () {
    final projected = projectionOf([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"false"}', response: "r1"),
        ran("c1", "nope", returnCode: 1),
      ]),
    ]);

    expect(projected.last.text, observation(returnCode: 1, output: "nope"));
  });

  // The answers are the answer; wrapping them as a command's outcome would put
  // the user's own words behind a return code.
  test("an ask_user result goes back as the answers themselves", () {
    final projected = projectionOf([
      said(MessageRole.assistant, [
        call("a1", askToolName, '{"questions":[]}', response: "r1"),
        ran("a1", "Which one? Rust"),
      ]),
    ]);

    expect(projected.last.text, "Which one? Rust");
  });

  // A provider that sees a tool call with no result rejects the next turn.
  test("a call whose result never landed is answered anyway", () {
    final projected = projectionOf([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"sleep 1000"}', response: "r1"),
      ]),
    ]);

    expect(projected.last.role, LlmRole.tool);
    expect(projected.last.toolCallId, "c1");
    expect(projected.last.text, contains("not executed"));
  });

  test("two calls in one response are answered in order, after it", () {
    final projected = projectionOf([
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

  test("what the user attached is named, not resent", () {
    final projected = projectionOf([
      said(MessageRole.user, const [
        MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this?"),
      ]),
    ]);

    expect(projected.single.text, "what is this?\n\n(attached: diagram.png)");
    expect(projected.single.attachments, isEmpty);
  });

  test("an error is the turn's own report, so it is not put back", () {
    final projected = projectionOf([
      asked("go"),
      said(MessageRole.assistant, const [
        MessagePart.text(text: "started", responseId: "r1"),
        MessagePart.error(message: "the provider gave up"),
      ]),
    ]);

    expect(projected.last.text, "started");
    expect(projected.map((m) => m.text).join(), isNot(contains("gave up")));
  });

  test("a message with nothing in it contributes nothing", () {
    expect(projectionOf([asked("   ".trim()), said(MessageRole.assistant, const [])]), isEmpty);
  });
}
