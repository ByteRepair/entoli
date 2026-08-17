import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_icon.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/app_theme.dart";
// Named, since the library's own `main` would otherwise be in scope beside the
// test's.
import "package:agent_chat/main.dart" show AgentChatApp;
import "package:agent_chat/providers.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  SegmentedButton<AppTheme> field(WidgetTester tester) =>
      tester.widget(find.byType(SegmentedButton<AppTheme>));

  /// What the page is drawing as chosen, rather than what the file says.
  AppTheme shown(WidgetTester tester) => field(tester).selected.single;

  Future<MaterialApp> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: app.container,
      child: AgentChatApp(onExit: () async {}),
    ));
    await settleIo(tester);
    return tester.widget<MaterialApp>(find.byType(MaterialApp));
  }

  group("the theme setting", () {
    testWidgets("a fresh install follows the system", (tester) async {
      expect(AppSettings.load(app.config).appTheme, AppTheme.system);
      await pumpAppearance(tester, app);

      expect(shown(tester), AppTheme.system);
    });

    testWidgets("they are offered in the order they are declared", (tester) async {
      await pumpAppearance(tester, app);

      expect(
        [for (final segment in field(tester).segments) segment.value],
        AppTheme.values,
      );
    });

    testWidgets("picking one persists it", (tester) async {
      await pumpAppearance(tester, app);

      await tester.tap(find.text(AppTheme.dark.label));
      await settleIo(tester);

      expect(AppSettings.load(app.config).appTheme, AppTheme.dark);
      expect(shown(tester), AppTheme.dark);
    });

    testWidgets("the choice survives a restart", (tester) async {
      app.seedSettings(AppSettings(appTheme: AppTheme.light));
      await pumpAppearance(tester, app);

      expect(shown(tester), AppTheme.light);
    });

    // The settings are one mutable object copied on every write, so a field
    // left out of `copy` is silently reset by the next save of any other.
    testWidgets("it survives the icon being changed beside it", (tester) async {
      await pumpAppearance(tester, app);
      await tester.tap(find.text(AppTheme.dark.label));
      await settleIo(tester);

      await tester.tap(find.text(AppIcon.prompt.label));
      await settleIo(tester);

      expect(AppSettings.load(app.config).appTheme, AppTheme.dark);
      expect(shown(tester), AppTheme.dark);
    });
  });

  group("what the app draws", () {
    testWidgets("both palettes are built, and the setting picks between them",
        (tester) async {
      app.seedSettings(AppSettings(appTheme: AppTheme.dark));
      final materialApp = await pumpApp(tester);

      expect(materialApp.themeMode, ThemeMode.dark);
      expect(materialApp.theme?.brightness, Brightness.light);
      expect(materialApp.darkTheme?.brightness, Brightness.dark);
    });

    testWidgets("following the system is what a fresh install hands over",
        (tester) async {
      final materialApp = await pumpApp(tester);

      expect(materialApp.themeMode, ThemeMode.system);
    });

    testWidgets("changing it re-themes without a restart", (tester) async {
      await pumpApp(tester);

      await io(
        tester,
        () => app.container.read(appSettingsProvider.notifier).setAppTheme(AppTheme.dark),
      );
      // A pump, not a settle: the config is right on the next build, and
      // settling would sit through Material's 200ms theme cross-fade.
      await tester.pump();

      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
    });
  });

  group("the stored name", () {
    test("a file with no theme, or one this build cannot read, follows the system",
        () async {
      await app.config.documents.write(app.config.settingsFile, '{"approveMode":"ask"}');
      expect(AppSettings.load(app.config).appTheme, AppTheme.system);

      await app.config.documents.write(app.config.settingsFile, '{"appTheme":"sepia"}');
      expect(AppSettings.load(app.config).appTheme, AppTheme.system);
    });
  });
}
