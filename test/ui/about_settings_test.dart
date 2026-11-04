import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pumpAbout(WidgetTester tester) =>
      pumpSettings(tester, app, SettingsCategory.about);

  testWidgets("the source tile opens the repository", (tester) async {
    await pumpAbout(tester);

    await tester.tap(find.text("Source on GitHub"));
    await settleIo(tester);

    expect(
      app.linkOpener.opened.single.toString(),
      "https://github.com/ByteRepair/entoli",
    );
  });

  testWidgets("the libraries are the licence page", (tester) async {
    await pumpAbout(tester);

    await tester.tap(find.text("Open source libraries"));
    await settleIo(tester);

    expect(find.byType(LicensePage), findsOneWidget);
  });
}
