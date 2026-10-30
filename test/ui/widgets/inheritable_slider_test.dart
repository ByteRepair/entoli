import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/resettable_field.dart";

void main() {
  const stops = [5, 10, 20, 40];

  Future<void> pump(
    WidgetTester tester, {
    int? value,
    int inherited = 20,
    ValueChanged<int?>? onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InheritableSlider(
            label: "Max generations per round",
            value: value,
            stops: stops,
            inherited: inherited,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    );
  }

  /// What the slider under test holds: its position read off the widget, so
  /// the label's painted text (shown only mid-drag) is not what is asserted.
  double positionOf(WidgetTester tester) =>
      tester.widget<Slider>(find.byType(Slider)).value;

  testWidgets("the track sits on the value, or the inherited one", (
    tester,
  ) async {
    await pump(tester);
    // 20 is the third of four stops.
    expect(positionOf(tester), 2);

    await pump(tester, value: 40, inherited: 10);
    expect(positionOf(tester), 3);
  });

  testWidgets("a value no stop carries reads as the nearest one", (
    tester,
  ) async {
    // 6 is a file's answer, not a stop: the slider shows 5 rather than
    // asserting.
    await pump(tester, value: 6, inherited: 10);
    expect(positionOf(tester), 0);
  });

  testWidgets("the reset reports the inherited stop and answers null", (
    tester,
  ) async {
    int? picked;
    await pump(tester, value: 40, inherited: 20, onChanged: (v) => picked = v);

    expect(find.byTooltip("Reset to the default (20)"), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(picked, isNull);
  });

  testWidgets("a drag answers the stop snapped to", (tester) async {
    int? picked;
    await pump(tester, value: 10, inherited: 10, onChanged: (v) => picked = v);

    final track = tester.getCenter(find.byType(Slider));
    final left = tester.getTopLeft(find.byType(Slider));
    final right = tester.getTopRight(find.byType(Slider));
    // Three divisions over four stops: the far end is the last one.
    await tester.dragFrom(
      Offset(left.dx + (right.dx - left.dx) * 0.95, track.dy),
      Offset.zero,
    );
    await tester.pumpAndSettle();
    expect(picked, 40);
  });
}
