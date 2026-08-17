import "package:flutter/material.dart";
import "package:flutter_svg/flutter_svg.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_icon.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/widgets/app_mark.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Finder choice(AppIcon icon) => find.ancestor(
        of: find.text(icon.label),
        matching: find.byType(InkWell),
      );

  /// What the page is drawing as chosen, rather than what the file says: the
  /// point of the section is that those agree.
  void expectSelected(WidgetTester tester, AppIcon icon, {required bool selected}) =>
      expect(tester.getSemantics(choice(icon)), isSemantics(isSelected: selected));

  group("app icon", () {
    testWidgets("a fresh install wears Cookie", (tester) async {
      final semantics = tester.ensureSemantics();
      expect(AppSettings.load(app.config).appIcon, AppIcon.cookie);
      await pumpAppearance(tester, app);

      expectSelected(tester, AppIcon.cookie, selected: true);
      expectSelected(tester, AppIcon.prompt, selected: false);
      semantics.dispose();
    });

    testWidgets("the default is offered first", (tester) async {
      await pumpAppearance(tester, app);
      expect(
        tester.getTopLeft(choice(AppIcon.cookie)).dx,
        lessThan(tester.getTopLeft(choice(AppIcon.prompt)).dx),
      );
    });

    testWidgets("picking one persists it and tells the launcher", (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpAppearance(tester, app);

      await tester.tap(choice(AppIcon.prompt));
      await settleIo(tester);
      expect(AppSettings.load(app.config).appIcon, AppIcon.prompt);
      expectSelected(tester, AppIcon.prompt, selected: true);

      await tester.tap(choice(AppIcon.cookie));
      await settleIo(tester);
      expect(AppSettings.load(app.config).appIcon, AppIcon.cookie);

      // Told each time, in order — not toggled.
      expect(app.launcher.used, [AppIcon.prompt, AppIcon.cookie]);
      semantics.dispose();
    });

    testWidgets("the choice survives a restart", (tester) async {
      final semantics = tester.ensureSemantics();
      app.seedSettings(AppSettings(appIcon: AppIcon.prompt));
      await pumpAppearance(tester, app);

      expectSelected(tester, AppIcon.prompt, selected: true);
      // Nothing was tapped, so the launcher was not told to do anything: it
      // has been showing this icon since it was picked.
      expect(app.launcher.used, isEmpty);
      semantics.dispose();
    });

    testWidgets("the section says the home screen follows", (tester) async {
      await pumpAppearance(tester, app);
      expect(find.textContaining("on the home screen"), findsOneWidget);
    });
  });

  group("without a launcher to change", () {
    setUp(() => app = TestApp.create(launcherIcons: false));

    testWidgets("the setting still applies, and says what it cannot do",
        (tester) async {
      await pumpAppearance(tester, app);
      expect(find.textContaining("does not follow this"), findsOneWidget);

      await tester.tap(choice(AppIcon.prompt));
      await settleIo(tester);

      // The in-app icon is the app's own either way; only the home screen
      // needs a platform that will take the change.
      expect(AppSettings.load(app.config).appIcon, AppIcon.prompt);
    });
  });

  group("what the app draws", () {
    testWidgets("the mark follows the setting", (tester) async {
      app.seedSettings(AppSettings(appIcon: AppIcon.prompt));
      await app.pump(tester, const Scaffold(body: AppMark()));
      expect(
        tester.widget<AppIconImage>(find.byType(AppIconImage)).icon,
        AppIcon.prompt,
      );
    });

    testWidgets("changing it redraws the mark without a restart", (tester) async {
      await app.pump(tester, const Scaffold(body: AppMark()));
      expect(
        tester.widget<AppIconImage>(find.byType(AppIconImage)).icon,
        AppIcon.cookie,
      );

      await io(tester, () => app.container.read(appSettingsProvider.notifier).setAppIcon(AppIcon.prompt));
      await settleIo(tester);

      expect(
        tester.widget<AppIconImage>(find.byType(AppIconImage)).icon,
        AppIcon.prompt,
      );
    });
  });

  group("the assets", () {
    // The rest of these tests find an AppIconImage whether or not its SVG
    // parsed, so without this a broken asset ships as a blank square.
    testWidgets("every icon is an SVG the app can draw", (tester) async {
      for (final icon in AppIcon.values) {
        await tester.runAsync(() async {
          final picture = await vg.loadPicture(SvgAssetLoader(icon.asset), null);
          expect(picture.size, const Size(108, 108), reason: icon.asset);
          picture.picture.dispose();
        });
      }
    });
  });

  group("the stored name", () {
    test("a name this build does not know falls back to the default", () async {
      await app.config.documents.write(app.config.settingsFile, '{"appIcon":"sawhorse"}');
      expect(AppSettings.load(app.config).appIcon, AppIcon.cookie);
    });

    test("an older file with no icon in it is the default", () async {
      await app.config.documents.write(app.config.settingsFile, '{"approveMode":"ask"}');
      expect(AppSettings.load(app.config).appIcon, AppIcon.cookie);
    });
  });
}
