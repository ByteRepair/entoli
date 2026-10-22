import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/chapter_rail.dart";

import "../harness.dart";

Message _said(String id, MessageRole role, String text) => Message(
    id: id, role: role, createdAt: DateTime(2026), parts: [TextPart(text: text)]);

void main() {
  test("a chapter is a prompt, branched wherever its turn was", () {
    final chat = Chat(
      state: makeState("c"),
      messages: [
        _said("u1", MessageRole.user, "first\nmore"),
        _said("a1", MessageRole.assistant, "reply"),
        _said("u2", MessageRole.user, "second"),
        _said("a2", MessageRole.assistant, "reply"),
        _said("u3", MessageRole.user, "third"),
      ],
      // An edit at the first prompt, a regenerate under the second.
      branches: {
        "u1": ["u1", "u1b"],
        "a2": ["a2x", "a2y", "a2"],
      },
    );

    final chapters = chaptersOf(chat);

    expect(chapters.map((c) => c.id), ["u1", "u2", "u3"]);
    expect(chapters.map((c) => c.preview), ["first", "second", "third"]);
    expect(chapters.map((c) => c.threads), [2, 3, 1]);
  });

  testWidgets("a branched chapter is marked, and says how many threads",
      (tester) async {
    final current = ValueNotifier<int?>(0);
    addTearDown(current.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChapterRail(
          chapters: const [
            (id: "u1", preview: "first", threads: 1),
            (id: "u2", preview: "second", threads: 2),
          ],
          current: current,
          onSelect: (_) {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.call_split), findsOneWidget);
    expect(find.byTooltip("second\n2 threads branch here"), findsOneWidget);
  });

  testWidgets("one prompt is no table of contents", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChapterRail(
        chapters: const [(id: "u1", preview: "first", threads: 1)],
        current: ValueNotifier(null),
        onSelect: (_) {},
      ),
    ));

    expect(find.byType(Tooltip), findsNothing);
  });
}
