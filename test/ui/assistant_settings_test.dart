import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/assistant_view.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpAssistant(WidgetTester tester) =>
      pumpSettings(tester, app, SettingsCategory.assistant);

  /// What a reload would read, rather than what the notifier is holding: the
  /// setting is only worth anything if it survives to the next launch, which is
  /// where an assistant gesture arrives from.
  AppSettings onDisk() => AppSettings.load(app.config);

  testWidgets("opens on the default project and the chat view", (tester) async {
    await pumpAssistant(tester);

    expect(find.text("Default"), findsOneWidget);
    expect(find.text("Chat view"), findsOneWidget);
  });

  testWidgets("every project is offered", (tester) async {
    await io(tester, () => app.repo.createProject("research"));
    await pumpAssistant(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();

    expect(popupLabels(tester), containsAll(<String>["Default", "research"]));
  });

  testWidgets("picking a project is written down", (tester) async {
    await io(tester, () => app.repo.createProject("research"));
    await pumpAssistant(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text("research").last);
    await settleIo(tester);

    expect(onDisk().assistantProject, "research");
  });

  testWidgets("picking the voice view is written down", (tester) async {
    await pumpAssistant(tester);

    await tester.tap(find.byType(DropdownButtonFormField<AssistantView>));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Voice view").last);
    await settleIo(tester);

    expect(onDisk().assistantView, AssistantView.voice);
  });

  testWidgets("a project that has since been deleted reads as the default one",
      (tester) async {
    await io(tester, () => app.seedSettings(AppSettings(assistantProject: "gone")));
    await pumpAssistant(tester);

    expect(find.text("Default"), findsOneWidget);
    expect(find.text("gone"), findsNothing);
  });
}
