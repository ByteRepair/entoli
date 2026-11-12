import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

import "../harness.dart";

void main() {
  group("the memory category", () {
    late TestApp app;

    setUp(() => app = TestApp.create());
    tearDown(() => app.dispose());

    testWidgets("holds the instructions and the auto-memory sections", (
      tester,
    ) async {
      app.seedSettings(AppSettings(autoMemory: false, memoryRecall: true));
      await pumpSettings(tester, app, SettingsCategory.memory);

      expect(find.text("Instructions"), findsOneWidget);
      expect(find.text("Auto memory"), findsOneWidget);
      // The model picker is behind the master: off, it is not drawn.
      expect(find.text("Memory LLM"), findsNothing);
      // The sub-gates are dead while the master is off.
      final switchTile = find.widgetWithText(
        SwitchListTile,
        "Recall relevant memories",
      );
      expect(tester.widget<SwitchListTile>(switchTile).onChanged, isNull);
      expect(
        app.container.read(appSettingsProvider).memoryRecall,
        isTrue,
        reason: "a dead sub-gate keeps its setting rather than clearing it",
      );
    });

    testWidgets("turning the master on offers the sub-gates and the model", (
      tester,
    ) async {
      app.seedSettings(AppSettings(autoMemory: true));
      await pumpSettings(tester, app, SettingsCategory.memory);

      expect(find.text("Keep memories"), findsOneWidget);
      expect(find.text("Recall relevant memories"), findsOneWidget);
      expect(find.text("Write memories after a turn"), findsOneWidget);
      expect(find.text("Memory tools"), findsOneWidget);
      expect(find.text("Memory LLM"), findsOneWidget);
    });
  });
}
