import "package:flutter/gestures.dart" show PointerDeviceKind;
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
          onSelect: (_, {required scrubbing}) {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.call_split), findsOneWidget);
    expect(find.byTooltip("second\n2 threads branch here"), findsOneWidget);
  });

  testWidgets("one prompt still has its tick", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChapterRail(
        chapters: const [(id: "u1", preview: "first", threads: 1)],
        current: ValueNotifier(null),
        onSelect: (_, {required scrubbing}) {},
      ),
    ));

    expect(find.byTooltip("first"), findsOneWidget);
  });

  test("a long prompt is cut to fifty characters", () {
    final long = "x" * 80;
    final chat = Chat(state: makeState("c"), messages: [
      _said("u1", MessageRole.user, long),
      _said("u2", MessageRole.user, "y" * 50),
    ]);

    final chapters = chaptersOf(chat);

    expect(chapters[0].preview, "${"x" * 50}...");
    // Exactly fifty is whole.
    expect(chapters[1].preview, "y" * 50);
  });

  testWidgets("a press selects, and a drag while pressed scrubs through each tick",
      (tester) async {
    final picked = <(int, bool)>[];
    final current = ValueNotifier<int?>(null);
    addTearDown(current.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: 400,
            child: ChapterRail(
              chapters: [
                for (var i = 0; i < 5; i++) (id: "u$i", preview: "p$i", threads: 1),
              ],
              current: current,
              onSelect: (i, {required scrubbing}) => picked.add((i, scrubbing)),
            ),
          ),
        ),
      ),
    ));

    final first = tester.getCenter(find.byTooltip("p0"));
    final pitch = tester.getCenter(find.byTooltip("p1")).dy - first.dy;
    final press = await tester.startGesture(first);
    // Selected on the way down, before anything is let go.
    expect(picked, [(0, false)]);

    // Moving within the tick it is on selects nothing new.
    await press.moveBy(Offset(0, pitch / 4));
    for (var i = 0; i < 3; i++) {
      await press.moveBy(Offset(0, pitch));
    }
    await press.up();

    expect(picked, [(0, false), (1, true), (2, true), (3, true)]);

    // A mouse passing over with no button down is a hover, not a scrub.
    picked.clear();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: first);
    await mouse.moveTo(tester.getCenter(find.byTooltip("p4")));
    await mouse.removePointer();

    expect(picked, isEmpty);
  });
}
