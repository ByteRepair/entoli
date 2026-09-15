import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/chip_row.dart";
import "package:agent_chat/ui/widgets/floating_position.dart";

void main() {
  // Chips 100 wide, 8 apart: one slot of travel is 108. The entry key is the
  // row's identity for the chip, so the fixture chip carries a distinct one
  // and the finders name the chip itself.
  Widget chip(String name) =>
      SizedBox(key: ValueKey("$name-chip"), width: 100, height: 40);

  Future<void> pumpRow(WidgetTester tester, List<String> names,
      {bool settled = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: ChipRow(
                settled: settled,
                entries: [
                  for (final name in names)
                    ChipRowEntry(key: ValueKey(name), child: chip(name)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Finder chipOf(String name) => find.byKey(ValueKey("$name-chip"));

  /// The slot the entry is grown into: the thing whose width the tween
  /// moves, since the chip's own box is full size from the first frame.
  RenderFloatingPosition slotOf(WidgetTester tester, String name) =>
      tester.renderObject<RenderFloatingPosition>(
        find.ancestor(of: chipOf(name), matching: find.byType(FloatingPosition)),
      );

  testWidgets("the first build grows in from nothing", (tester) async {
    await pumpRow(tester, ["a", "b"]);
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-growth: both entries are on screen, part grown.
    expect(chipOf("a"), findsOneWidget);
    expect(chipOf("b"), findsOneWidget);
    expect(slotOf(tester, "a").size.width, lessThan(100.0));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(chipOf("a"), findsOneWidget);
    expect(chipOf("b"), findsOneWidget);
  });

  testWidgets("a settled row shows full size on its first build", (tester) async {
    await pumpRow(tester, ["a", "b"], settled: true);
    await tester.pump(const Duration(milliseconds: 60));

    // Not part grown: the flag snapshot makes the first tween degenerate, so
    // what the row is built with is already there.
    expect(slotOf(tester, "a").size.width, 100.0);
    expect(slotOf(tester, "b").size.width, 100.0);

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(slotOf(tester, "a").size.width, 100.0);
  });

  testWidgets("a settled row animates what arrives after it", (tester) async {
    await pumpRow(tester, ["a", "b"], settled: true);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));

    // The screen's own sequence: opened settled, then a change. What arrives
    // now was not on the row it was built with, so it grows in as always.
    await pumpRow(tester, ["a", "b", "c"], settled: true);
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-growth: "c" is on screen but its slot is not yet full.
    expect(chipOf("c"), findsOneWidget);
    expect(slotOf(tester, "c").size.width, lessThan(100.0));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(slotOf(tester, "c").size.width, 100.0);
  });

  testWidgets("a removal shrinks away before it goes", (tester) async {
    await pumpRow(tester, ["a", "b"]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));

    await pumpRow(tester, ["a"]);
    await tester.pump(const Duration(milliseconds: 60));

    // Held for the shrink: the leaving chip is still on screen mid-motion.
    expect(chipOf("b"), findsOneWidget);

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(chipOf("b"), findsNothing);
  });

  testWidgets("a key back mid-exit revives the entry", (tester) async {
    await pumpRow(tester, ["a", "b"]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));

    await pumpRow(tester, ["a"]);
    await tester.pump(const Duration(milliseconds: 60));

    // Mid-shrink, "b" comes back: it stays on screen past the hold the exit
    // scheduled, and settles rather than vanishing.
    await pumpRow(tester, ["a", "b"]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));

    expect(chipOf("b"), findsOneWidget);
  });

  testWidgets("a kept entry glides as its neighbours open and shut around it",
      (tester) async {
    // Two chips in the row: "a" settles centre-left at 46.
    await pumpRow(tester, ["a", "b"]);
    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    final before = tester.getTopLeft(chipOf("a"));
    expect(before.dx, 46.0);

    // "b" leaves: "a" slides to the lone slot at 100.
    await pumpRow(tester, ["a"]);
    await tester.pump(const Duration(milliseconds: 60));

    // While the leaving chip shrinks, "a"'s slot moves frame by frame and the
    // paint chases it: the painted position and the settled one disagree
    // mid-motion, which is the glide.
    final a = slotOf(tester, "a");
    expect(a.paintedOffset.dx, isNot(a.localToGlobal(Offset.zero).dx));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(tester.getTopLeft(chipOf("a")).dx, 100);
  });
}