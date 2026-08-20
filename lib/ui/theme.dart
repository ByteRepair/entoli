import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart";

import "../domain/app_theme.dart";

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

/// The app's palette, in the brightness asked for. Every field and dropdown is
/// outlined, so the border is here rather than at each of them — see "The
/// theme". A field passing its own still wins.
ThemeData entoliTheme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: entoliIndigo,
        brightness: brightness,
      ),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );

extension AppThemeMode on AppTheme {
  ThemeMode get mode => switch (this) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      };
}
