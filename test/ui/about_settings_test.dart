import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/theme.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpAbout(WidgetTester tester) =>
      pumpSettings(tester, app, SettingsCategory.about);

  testWidgets("says what is running and who wrote it", (tester) async {
    await pumpAbout(tester);

    expect(find.text(appTitle), findsOneWidget);
    expect(find.text("Version $testAppVersion"), findsOneWidget);
    expect(find.text("Made by Yiannis Charalambous"), findsOneWidget);
  });

  testWidgets("the source tile opens the repository", (tester) async {
    await pumpAbout(tester);

    await tester.tap(find.text("Source on GitHub"));
    await settleIo(tester);

    expect(app.linkOpener.opened.single.toString(),
        "https://github.com/Yiannis128/agent-chat");
  });

  testWidgets("the libraries are the licence page", (tester) async {
    await pumpAbout(tester);

    await tester.tap(find.text("Open source libraries"));
    await settleIo(tester);

    expect(find.byType(LicensePage), findsOneWidget);
  });
}
