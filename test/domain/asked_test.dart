import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

Message _message(String id, MessageRole role, String text) => Message(
  id: id,
  role: role,
  createdAt: DateTime(2026),
  parts: [MessagePart.text(text: text)],
);

void main() {
  group("Asked.fromLog", () {
    final log = [
      _message("u1", MessageRole.user, "set up the dependencies"),
      _message("a1", MessageRole.assistant, "I'll run npm install next."),
      _message("u2", MessageRole.user, "  "),
    ];

    test("a new turn's message answers the last reply in the log", () {
      final said = _message("u3", MessageRole.user, "do this");
      final asked = Asked.fromLog(log, said);
      expect(asked.said, "do this");
      expect(asked.earlier, ["set up the dependencies"]);
      expect(asked.answering, "I'll run npm install next.");
      expect(asked.steered, isEmpty);
    });

    test("a resumed turn's message is read where it sits in the log", () {
      final said = _message("u3", MessageRole.user, "do this");
      final asked = Asked.fromLog([
        ...log,
        said,
        _message("a2", MessageRole.assistant, "Running it now"),
      ], said);
      expect(asked.earlier, ["set up the dependencies"]);
      expect(
        asked.answering,
        "I'll run npm install next.",
        reason: "the interrupted turn's own reply is not what was answered",
      );
    });

    test("a steer is added after what was steered before", () {
      final asked = Asked(said: "go", steered: ["one"]).steer(" two ");
      expect(asked.steered, ["one", "two"]);
      expect(asked.said, "go");
    });
  });

  test("a request with nothing to say is none", () {
    expect(
      ClassifierRequest.of(
        asked: Asked(said: " "),
        goal: "",
      ),
      isNull,
    );
    expect(ClassifierRequest.of(goal: "ship it"), isNotNull);
  });
}
