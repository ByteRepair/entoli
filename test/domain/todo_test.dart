import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/todo.dart";

String _args(List<(String, String)> items) => jsonEncode({
  "todos": [
    for (final (content, status) in items)
      {"content": content, "status": status},
  ],
});

Message _reply(String id, List<(String, String)> items, {int returnCode = 0}) =>
    Message(
      id: id,
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      parts: [
        MessagePart.toolCall(
          toolCall: ToolCall(
            id: "c-$id",
            name: todoToolName,
            argumentsJson: _args(items),
          ),
        ),
        MessagePart.toolResult(
          result: ToolResult(
            callId: "c-$id",
            returnCode: returnCode,
            output: "",
          ),
        ),
      ],
    );

Message _prompt(String id) => Message(
  id: id,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  parts: const [MessagePart.text(text: "next")],
);

void main() {
  test("a list with an unknown status or an empty task is not one", () {
    expect(TodoList.parse(_args([("one", "started")])), isNull);
    expect(TodoList.parse(_args([("  ", "pending")])), isNull);
    expect(TodoList.parse('{"todos": "one"}'), isNull);
    expect(TodoList.parse(_args([])), isNotNull);
  });

  test("the newest call that ran is the list; a refused one wrote none", () {
    final list = TodoList.latestIn([
      _reply("a", [("first", "pending")]),
      _reply("b", [("refused", "pending")], returnCode: 1),
    ]);

    expect(list!.items.single.content, "first");
  });

  test("a new prompt puts the last turn's list away", () {
    final earlier = _reply("a", [("one", "pending")]);

    expect(TodoList.ofLastTurn([_prompt("p"), earlier]), isNotNull);
    expect(TodoList.ofLastTurn([earlier, _prompt("p")]), isNull);
  });
}
