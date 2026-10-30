import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";

import "../fakes.dart";
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

/// General's Update section: the row exists exactly where a platform half
/// does, and the switch is the setting, written the way an off-by-default
/// bool is — only when it is off.
void main() {
  late TestApp app;
  tearDown(() => app.dispose());

  testWidgets("the row is drawn where a platform half exists", (tester) async {
    app = TestApp.create(updateHost: FakeAppUpdateHost(available: true));
    await pumpSettings(tester, app, SettingsCategory.general);

    await scrollTo(tester, find.text("Automatically update"));

    expect(find.text("Automatically update"), findsOneWidget);
    expect(find.text("Update"), findsOneWidget);
  });

  testWidgets("and nowhere a platform half does not", (tester) async {
    app = TestApp.create();
    await pumpSettings(tester, app, SettingsCategory.general);

    // The section sits at the end of General, past the last row, so reaching
    // that row is reaching everything the list has.
    await scrollTo(tester, find.text("Delete all chats"));

    expect(find.text("Automatically update"), findsNothing);
    expect(find.text("Update"), findsNothing);
  });

  testWidgets("the switch is the setting, written only when off", (
    tester,
  ) async {
    app = TestApp.create(updateHost: FakeAppUpdateHost(available: true));
    await pumpSettings(tester, app, SettingsCategory.general);
    await scrollTo(tester, find.text("Automatically update"));
    expect(
      AppSettings.load(app.config).autoUpdate,
      isTrue,
      reason: "on is the default, and what nothing written means",
    );

    await tester.tap(find.text("Automatically update"));
    await settleIo(tester);

    expect(AppSettings.load(app.config).autoUpdate, isFalse);

    await tester.tap(find.text("Automatically update"));
    await settleIo(tester);

    expect(AppSettings.load(app.config).autoUpdate, isTrue);
    // Back on is not written: a file the switch leaves says nothing about it
    // and gets the on default, the way every off-defaulting bool here reads.
    expect(
      app.config.documents.read(app.config.settingsFile),
      isNot(contains("autoUpdate")),
    );
  });
}
