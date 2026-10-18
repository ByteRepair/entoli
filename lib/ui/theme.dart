import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/brand.dart";
import "../domain/app_theme.dart";
import "../domain/theme_colour.dart";
import "fonts.dart";
import "../providers.dart";

/// The indigo the icon sits on, which is `ThemeColour.indigo` as a `Color`. The
/// copies in `assets/icons/`, the Android drawable and `web/manifest.json` are
/// this colour written again — there is no generator, so changing it here does
/// not move them.
const entoliIndigo = Color(entoliIndigoArgb);

/// The app's name, wherever it is shown from Dart. It has to agree with
/// `@string/app_name`, which `src/debug/` overrides: `MaterialApp.title` is the
/// Android recents entry and *replaces* the launcher label there, so without
/// this a debug build would name itself twice and differently.
const appTitle = appBrand;

/// The two voices on the voice screen, and the only colours in the app not
/// taken from the scheme. A scheme's tones are picked to be *read on* a
/// surface: `primary` in the dark is nearly white, which makes a pale smudge of
/// something meant to be lit, and `tertiary` resolves an indigo seed to a rose
/// that reads as a warning rather than as the other half of a conversation.
/// Both are deeper in light mode, where an orb has to be a colour rather than a
/// glow.
Color heardColour(Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFF6C63FF) : entoliIndigo;

Color spokenColour(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF2DD4BF)
    : const Color(0xFF0E9384);

/// What the app is drawn with: the settings resolved against the system's own
/// palette, so `main` watches one thing and the rule that an accent replaces
/// both colours is written once.
final appLookProvider = Provider<AppLook>((ref) {
  final accent = ref.watch(paletteAccentProvider);
  final settings = ref.watch(appSettingsProvider.select(
      (s) => (primary: s.primaryColour, secondary: s.secondaryColour, radius: s.cornerRadius)));
  return (
    primary: accent == null ? settings.primary.colour : Color(accent),
    secondary: accent == null ? settings.secondary.colour : null,
    radius: settings.radius.radius,
  );
});

/// A seed, the seed of the accent group beside it, and how round a corner is.
typedef AppLook = ({Color primary, Color? secondary, double radius});

const entoliLook = (primary: entoliIndigo, secondary: null, radius: 12.0);

/// The app's palette, in the brightness asked for. A null `secondary` derives
/// it from the primary seed, which is what Material does with one seed.
///
/// Every field and dropdown is outlined, so the border is here rather than at
/// each of them — see "The theme". A field passing its own still wins. The
/// radius reaches the same set: fields, cards, dialogs, menus, sheets and
/// buttons.
ThemeData entoliTheme(Brightness brightness, [AppLook look = entoliLook]) {
  final corners = BorderRadius.circular(look.radius);
  final shape = RoundedRectangleBorder(borderRadius: corners);
  final buttons = ButtonStyle(shape: WidgetStatePropertyAll(shape));
  return ThemeData(
    colorScheme: _scheme(brightness, look.primary, look.secondary),
    fontFamily: bodyFamily,
    textTheme: _displayTiers,
    inputDecorationTheme:
        InputDecorationTheme(border: OutlineInputBorder(borderRadius: corners)),
    cardTheme: CardThemeData(shape: shape),
    dialogTheme: DialogThemeData(shape: shape),
    popupMenuTheme: PopupMenuThemeData(shape: shape),
    menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(shape))),
    // Square against the edge it is anchored to.
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(look.radius)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
  );
}

/// The tiers that leave the body face for Playfair Display. Passed as a
/// partial `textTheme:`, it merges over what `ThemeData` built with
/// `fontFamily: bodyFamily` — only the family moves, and the geometry (sizes,
/// weights, letter-spacing) stays whatever the constructor resolved for the
/// platform and scheme. `titleMedium` (16pt) is the lowest tier on the
/// display face; `titleSmall` (14pt) and below stay on the body face, where
/// buttons and timestamps of a UI read as prose rather than as a poster.
const _displayTiers = TextTheme(
  displayLarge: TextStyle(fontFamily: displayFamily),
  displayMedium: TextStyle(fontFamily: displayFamily),
  displaySmall: TextStyle(fontFamily: displayFamily),
  headlineLarge: TextStyle(fontFamily: displayFamily),
  headlineMedium: TextStyle(fontFamily: displayFamily),
  headlineSmall: TextStyle(fontFamily: displayFamily),
  titleLarge: TextStyle(fontFamily: displayFamily),
  titleMedium: TextStyle(fontFamily: displayFamily),
);

/// The secondary is grafted from a scheme seeded with it rather than passed to
/// `fromSeed` flat: that names one role, leaving `secondaryContainer` a tone of
/// the primary seed beside a colour that is not. The same colour twice would
/// graft what is already there, so it skips a scheme instead.
ColorScheme _scheme(Brightness brightness, Color primary, Color? secondary) {
  final scheme = ColorScheme.fromSeed(seedColor: primary, brightness: brightness);
  if (secondary == null || secondary == primary) return scheme;
  final accent = ColorScheme.fromSeed(seedColor: secondary, brightness: brightness);
  return scheme.copyWith(
    secondary: accent.secondary,
    onSecondary: accent.onSecondary,
    secondaryContainer: accent.secondaryContainer,
    onSecondaryContainer: accent.onSecondaryContainer,
  );
}

extension ThemeColourValue on ThemeColour {
  Color get colour => Color(argb);
}

extension AppThemeMode on AppTheme {
  ThemeMode get mode => switch (this) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      };
}
