import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_category.dart";
import "package:agent_chat/ui/widgets/decorative_motion.dart";
import "package:agent_chat/ui/widgets/thinking_slider.dart";

import "../harness.dart";

void main() {
  /// A slider of three points, moving unless [motion] is off. It never comes
  /// to rest while it moves, so what follows a pick is a frame, not a settle:
  /// a pick lands on the tap or the key itself.
  Future<int Function()> pumpSlider(
    WidgetTester tester, {
    bool motion = true,
  }) async {
    var value = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: DecorativeMotion(
          enabled: motion,
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                width: 400,
                child: ThinkingSlider(
                  stops: const {0: "Less", 1: "Some", 2: "More"},
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return () => value;
  }

  testWidgets("it moves for as long as it is on screen, and not when told", (
    tester,
  ) async {
    await pumpSlider(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await pumpSlider(tester, motion: false);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets("a point is picked by tapping it, or by the arrow keys", (
    tester,
  ) async {
    final value = await pumpSlider(tester);
    for (final label in ["Less", "Some", "More"]) {
      expect(find.text(label), findsOneWidget);
    }

    // The bar is three equal parts, one point in the middle of each.
    final bar = tester.getRect(find.byType(CustomPaint).last);
    await tester.tapAt(bar.centerRight - const Offset(10, 0));
    await tester.pump();
    expect(value(), 2);

    await tester.tap(find.byType(CustomPaint).last);
    await tester.pump();
    expect(value(), 1);

    Focus.of(tester.element(find.byType(CustomPaint).last)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value(), 0);
  });

  testWidgets("Settings > LLMs sets how long the model thinks", (tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    await pumpSettings(tester, app, SettingsCategory.llms);
    await scrollTo(tester, find.text("Thinking"));

    await tester.tap(find.text("High"));
    await settleIo(tester);
    expect(
      app.container.read(appSettingsProvider).reasoningEffort,
      ReasoningEffort.high,
    );
    expect(AppSettings.load(app.config).reasoningEffort, ReasoningEffort.high);
  });
}
