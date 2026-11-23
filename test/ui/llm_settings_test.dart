import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:entoli_chat/domain/app_settings.dart";
import "package:entoli_chat/domain/settings/keys.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  AppSettings settings() => app.container.read(appSettingsProvider);

  Future<void> pumpTurns(WidgetTester tester) async {
    useWindow(tester, const Size(1200, 1600));
    await pumpSettings(tester, app, SettingsCategory.llms);
    await scrollTo(tester, find.text("Turns"));
  }

  Future<void> typeTotalContext(WidgetTester tester, String text) async {
    await scrollTo(tester, find.text("256k tokens"));
    await tester.tap(find.text("256k tokens"));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.tap(find.text("Save"));
    await settleIo(tester);
  }

  testWidgets("retrying is a switch, and off writes no retries", (
    tester,
  ) async {
    await pumpTurns(tester);

    expect(settings().turnRetries, SettingKeys.defaultTurnRetries);
    expect(
      find.textContaining("Carried on automatically up to 5 times"),
      findsOneWidget,
    );

    await tester.tap(find.text("Automatic retry"));
    await settleIo(tester);

    expect(settings().turnRetries, 0);
    expect(find.textContaining("Carried on automatically"), findsNothing);
  });

  testWidgets("total context is typed, and held to its bounds", (tester) async {
    await pumpTurns(tester);

    await typeTotalContext(tester, "1,000");

    expect(settings().totalContext, SettingKeys.minTotalContext);
    expect(find.text("${SettingKeys.minTotalContext} tokens"), findsOneWidget);
  });

  testWidgets("a total context that is not a number is said, not dropped", (
    tester,
  ) async {
    await pumpTurns(tester);

    await typeTotalContext(tester, "lots");

    expect(settings().totalContext, SettingKeys.defaultTotalContext);
    expect(find.text("\"lots\" is not a number."), findsOneWidget);
  });
}
