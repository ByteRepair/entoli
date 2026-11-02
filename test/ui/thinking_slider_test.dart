import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_category.dart";
import "package:agent_chat/ui/widgets/thinking_slider.dart";

import "../harness.dart";

void main() {
  testWidgets("a point is picked by tapping it, or by the arrow keys", (
    tester,
  ) async {
    var value = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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
    );
    for (final label in ["Less", "Some", "More"]) {
      expect(find.text(label), findsOneWidget);
    }

    // The bar is three equal parts, one point in the middle of each.
    final bar = tester.getRect(find.byType(CustomPaint).last);
    await tester.tapAt(bar.centerRight - const Offset(10, 0));
    await tester.pumpAndSettle();
    expect(value, 2);

    await tester.tap(find.byType(CustomPaint).last);
    await tester.pumpAndSettle();
    expect(value, 1);

    Focus.of(tester.element(find.byType(CustomPaint).last)).requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(value, 0);
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
