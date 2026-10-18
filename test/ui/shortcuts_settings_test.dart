import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/shortcuts.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  testWidgets("lists every shortcut with its keys", (tester) async {
    await pumpSettings(tester, app, SettingsCategory.shortcuts);

    for (final shortcut in AppShortcut.values) {
      expect(find.text(shortcut.label), findsOneWidget);
    }
    expect(find.text("Ctrl"), findsNWidgets(AppShortcut.values.length));
    expect(find.text("Shift"), findsOneWidget);
    expect(find.text("Alt"), findsOneWidget);
  });
}
