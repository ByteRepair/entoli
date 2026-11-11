import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/app_command.dart";

import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  testWidgets("lists every command that has keys, with its keys", (
    tester,
  ) async {
    await pumpSettings(tester, app, SettingsCategory.shortcuts);

    final keyed = appItems.where((c) => c.key != null);
    for (final command in keyed) {
      expect(find.text(command.title), findsOneWidget);
    }
    expect(find.text("Ctrl"), findsNWidgets(keyed.length));
    expect(find.text("Shift"), findsNWidgets(2));
    expect(find.text("Alt"), findsNWidgets(2));
  });
}
