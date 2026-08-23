import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart";

import "../domain/app_theme.dart";
import "../domain/corner_radius.dart";
import "../domain/theme_colour.dart";

/// The indigo the icon sits on. The copies in `assets/icons/`, the Android
/// drawable and `web/manifest.json` are this colour written again — there is no
/// generator, so changing it here does not move them.
const entoliIndigo = Color(0xFF4F46E5);

/// The app's name, wherever it is shown from Dart. It has to agree with
/// `@string/app_name`, which `src/debug/` overrides: `MaterialApp.title` is the
/// Android recents entry and *replaces* the launcher label there, so without
/// this a debug build would name itself twice and differently.
const appTitle = kDebugMode ? "Entoli (Debug)" : "Entoli";

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

/// The app's palette, in the brightness asked for, seeded from [primary] and
/// rounded to [radius]. A [secondary] is the seed of the accent group beside
/// the primary one; null derives it from [primary], which is what Material
/// does with one seed.
///
/// Every field and dropdown is outlined, so the border is here rather than at
/// each of them — see "The theme". A field passing its own still wins.
ThemeData entoliTheme(
  Brightness brightness, {
  Color primary = entoliIndigo,
  Color? secondary,
  double radius = defaultCornerRadius,
}) {
  final corners = BorderRadius.circular(radius);
  final shape = RoundedRectangleBorder(borderRadius: corners);
  final buttons = ButtonStyle(shape: WidgetStatePropertyAll(shape));
  return ThemeData(
    colorScheme: _scheme(brightness, primary, secondary),
    inputDecorationTheme:
        InputDecorationTheme(border: OutlineInputBorder(borderRadius: corners)),
    dialogTheme: DialogThemeData(shape: shape),
    popupMenuTheme: PopupMenuThemeData(shape: shape),
    menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(shape))),
    // A sheet is rounded along the edge it comes in from and square against
    // the one it is anchored to.
    bottomSheetTheme: BottomSheetThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
  );
}

/// The secondary is grafted from a scheme seeded with it rather than passed to
/// `fromSeed` flat: that names one role, leaving `secondaryContainer` a tone of
/// the primary seed beside a colour that is not.
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
