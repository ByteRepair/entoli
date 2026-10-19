import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_icon.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/app_theme.dart";
import "package:agent_chat/domain/corner_radius.dart";
import "package:agent_chat/domain/theme_colour.dart";
import "package:agent_chat/ui/theme.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";
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

  /// A swatch or a corner in the row labelled [row], and within it the
  /// [group] of swatches where given. Scoped because the two colour rows offer
  /// the same tooltips, and bold and pastel share some names.
  Future<void> tapChoice(WidgetTester tester, String row, String choice,
      {String? group}) async {
    var scope =
        find.ancestor(of: find.text(row), matching: find.byType(LabelledField));
    if (group != null) {
      scope = find
          .ancestor(
            of: find.descendant(of: scope, matching: find.text(group)),
            matching: find.byType(Column),
          )
          .first;
    }
    final target = find.descendant(of: scope, matching: find.byTooltip(choice));
    await scrollTo(tester, target);
    await tester.tap(target);
    await settleIo(tester);
  }

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

  group("the palette", () {
    testWidgets("a fresh install is seeded from the app's own indigo",
        (tester) async {
      final materialApp = await pumpApp(tester);

      expect(
        materialApp.theme?.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: entoliIndigo).primary,
      );
    });

    testWidgets("the primary colour is what the scheme is seeded from",
        (tester) async {
      app.seedSettings(AppSettings(primaryColour: ThemeColour.teal));
      final materialApp = await pumpApp(tester);

      expect(
        materialApp.theme?.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: ThemeColour.teal.colour).primary,
      );
    });

    testWidgets("the secondary colour brings its container with it", (tester) async {
      app.seedSettings(AppSettings(secondaryColour: ThemeColour.amber));
      final scheme = (await pumpApp(tester)).theme!.colorScheme;

      final amber = ColorScheme.fromSeed(seedColor: ThemeColour.amber.colour);
      expect(scheme.primary, ColorScheme.fromSeed(seedColor: entoliIndigo).primary);
      expect(scheme.secondary, amber.secondary);
      expect(scheme.secondaryContainer, amber.secondaryContainer);
    });

    testWidgets("the corner radius reaches the shapes the theme sets",
        (tester) async {
      app.seedSettings(AppSettings(cornerRadius: CornerRadius.extraLarge));
      final theme = (await pumpApp(tester)).theme!;

      final corners = BorderRadius.circular(CornerRadius.extraLarge.radius);
      expect(
        (theme.dialogTheme.shape as RoundedRectangleBorder).borderRadius,
        corners,
      );
      expect(
        (theme.inputDecorationTheme.border as OutlineInputBorder).borderRadius,
        corners,
      );
    });

    testWidgets("picking a colour persists it, one row at a time", (tester) async {
      await pumpAppearance(tester, app);

      await tapChoice(tester, "Primary colour", ThemeColour.green.label,
          group: "Pastel colours");
      await tapChoice(tester, "Secondary colour", ThemeColour.boldGreen.label,
          group: "Bold colours");

      final saved = AppSettings.load(app.config);
      expect(saved.primaryColour, ThemeColour.green);
      expect(saved.secondaryColour, ThemeColour.boldGreen);
    });

    testWidgets("picking a theme sets both colours", (tester) async {
      await pumpAppearance(tester, app);

      await tapChoice(tester, "Theme colours", ColourTheme.dracula.label);
      var saved = AppSettings.load(app.config);
      expect(saved.primaryColour, ThemeColour.draculaPurple);
      expect(saved.secondaryColour, ThemeColour.draculaPink);

      await tapChoice(tester, "Theme colours", ColourTheme.adwaita.label);
      saved = AppSettings.load(app.config);
      expect(saved.primaryColour, ThemeColour.adwaita);
      expect(saved.secondaryColour, ThemeColour.adwaita);
    });

    testWidgets("a bold colour keeps its chroma, where a pastel is softened",
        (tester) async {
      app.seedSettings(AppSettings(
          primaryColour: ThemeColour.boldRed, secondaryColour: ThemeColour.red));
      final scheme = (await pumpApp(tester)).theme!.colorScheme;

      final bold = ColorScheme.fromSeed(
          seedColor: ThemeColour.boldRed.colour,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
      final pastel = ColorScheme.fromSeed(seedColor: ThemeColour.red.colour);
      expect(scheme.primary, bold.primary);
      expect(scheme.secondary, pastel.secondary);
      expect(bold.primary, isNot(pastel.primary));
    });

    testWidgets("picking a corner persists it", (tester) async {
      await pumpAppearance(tester, app);

      await tapChoice(tester, "Corners", "20");

      expect(AppSettings.load(app.config).cornerRadius, CornerRadius.largeIncreased);
    });
  });

  group("Material 3 Expressive", () {
    testWidgets("a platform with no palette of its own is not offered it",
        (tester) async {
      await pumpAppearance(tester, app);

      expect(find.text("Material 3 Expressive"), findsNothing);
      expect(find.text("Primary colour"), findsOneWidget);
    });

    group("on a phone that has one", () {
      const accent = 0xFF7B5800;

      setUp(() => app = TestApp.create(systemAccent: accent));

      testWidgets("it is off until it is turned on, and then there is nothing "
          "left to pick", (tester) async {
        await pumpAppearance(tester, app);
        expect(AppSettings.load(app.config).systemPalette, isFalse);

        await scrollTo(tester, find.text("Material 3 Expressive"));
        await tester.tap(find.text("Material 3 Expressive"));
        await settleIo(tester);

        expect(AppSettings.load(app.config).systemPalette, isTrue);
        expect(find.text("Theme colours"), findsNothing);
        expect(find.text("Primary colour"), findsNothing);
        expect(find.text("Secondary colour"), findsNothing);
      });

      testWidgets("the palette is seeded from the system's accent", (tester) async {
        app.seedSettings(
            AppSettings(systemPalette: true, primaryColour: ThemeColour.red));
        final materialApp = await pumpApp(tester);

        expect(
          materialApp.theme?.colorScheme.primary,
          ColorScheme.fromSeed(seedColor: const Color(accent)).primary,
        );
      });

      testWidgets("turning it off returns to the colour that was picked",
          (tester) async {
        app.seedSettings(
            AppSettings(systemPalette: true, primaryColour: ThemeColour.red));
        await pumpApp(tester);

        await io(
          tester,
          () =>
              app.container.read(appSettingsProvider.notifier).setSystemPalette(false),
        );
        await tester.pump();

        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).theme?.colorScheme.primary,
          ColorScheme.fromSeed(seedColor: ThemeColour.red.colour).primary,
        );
      });
    });
  });

  group("the stored name", () {
    test("a file with no theme, or one this build cannot read, follows the system",
        () async {
      await app.config.documents.write(app.config.settingsFile, '{"approveMode":"ask"}');
      expect(AppSettings.load(app.config).appTheme, AppTheme.system);

      await app.config.documents.write(app.config.settingsFile, '{"appTheme":"sepia"}');
      expect(AppSettings.load(app.config).appTheme, AppTheme.system);

      // A colour or a radius this build does not offer falls back, and one it
      // offers is kept; the fallback is per field.
      await app.config.documents.write(app.config.settingsFile,
          '{"primaryColour":"chartreuse","secondaryColour":"teal","cornerRadius":"sharp"}');

      final saved = AppSettings.load(app.config);
      expect(saved.primaryColour, ThemeColour.indigo);
      expect(saved.secondaryColour, ThemeColour.teal);
      expect(saved.cornerRadius, CornerRadius.medium);
    });
  });
}
