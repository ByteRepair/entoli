import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/floating_position.dart";

void main() {
  // Chips 100 wide with 8 between them: one slot of travel is 108. The wrap
  // is given a fixed width so its center alignment has room to distribute —
  // on the screen itself the column is what centres the wrap, which moves
  // every settled offset the same way.

  Future<void> pumpChips(
    WidgetTester tester,
    List<double> widths, {
    double width = 300,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < widths.length; i++)
                    FloatingPosition(
                      key: ValueKey("chip$i"),
                      child: SizedBox(width: widths[i], height: 40),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  RenderFloatingPosition renderOf(WidgetTester tester, int index) =>
      tester.renderObject<RenderFloatingPosition>(
        find.byType(FloatingPosition).at(index),
      );

  testWidgets("appears where the wrap put it, with nothing to glide from",
      (tester) async {
    // 208 of chips in a 300 row: 46 of leading space either side.
    await pumpChips(tester, [100, 100]);

    expect(renderOf(tester, 0).paintedOffset, const Offset(46, 0));
    expect(renderOf(tester, 1).paintedOffset, const Offset(154, 0));
  });

  testWidgets("a neighbour's growth glides this one aside", (tester) async {
    await pumpChips(tester, [100, 100]);
    await pumpChips(tester, [132, 100]);
    await tester.pump(const Duration(milliseconds: 60));

    // The grown row is 240 wide, so the second chip's slot is 170; mid-flight
    // it is part of the way from 154, not snapped.
    final painted = renderOf(tester, 1).paintedOffset;
    expect(painted.dx, greaterThan(154));
    expect(painted.dx, lessThan(170));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(renderOf(tester, 1).paintedOffset, const Offset(170, 0));
  });

  testWidgets("a push onto the next line glides down as well as across",
      (tester) async {
    // 208 in a 250 row: both on one line, the second at 129.
    await pumpChips(tester, [100, 100], width: 250);
    // The first chip grows past what the line holds, so the second one is
    // pushed onto the second line, centred there at (75, 48).
    await pumpChips(tester, [150, 100], width: 250);
    await tester.pump(const Duration(milliseconds: 60));

    final painted = renderOf(tester, 1).paintedOffset;
    expect(painted.dy, greaterThan(0));
    expect(painted.dy, lessThan(48));
    expect(painted.dx, lessThan(129));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    expect(renderOf(tester, 1).paintedOffset, const Offset(75, 48));
  });

  testWidgets("a tap lands where the child is painted", (tester) async {
    var pressed = false;
    Future<void> build({required double first}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  FloatingPosition(
                    key: const ValueKey("first"),
                    child: SizedBox(width: first, height: 40),
                  ),
                  FloatingPosition(
                    key: const ValueKey("button"),
                    child: TextButton(
                      onPressed: () => pressed = true,
                      child: const SizedBox(width: 100, height: 40),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await build(first: 100);
    await tester.pumpAndSettle();

    // The button's slot jumps from 108 to 148 when the first chip grows; the
    // tap lands where the button is currently shown, which is short of the
    // slot and yet still on the button.
    await build(first: 140);
    await tester.pump(const Duration(milliseconds: 60));
    final painted = renderOf(tester, 1).paintedOffset;
    expect(painted.dx, lessThan(148));

    await tester.pumpAndSettle(const Duration(milliseconds: 16));
    final settled = renderOf(tester, 1).paintedOffset;
    final origin = tester.getTopLeft(find.byType(TextButton));
    await tester.tapAt(
      origin + (painted - settled) + const Offset(50, 20),
    );
    expect(pressed, isTrue);
  });
}