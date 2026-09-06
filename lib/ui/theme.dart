import "package:flutter/foundation.dart" show kDebugMode;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

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
/// The text theme is set in the faces the artifact stylesheet names — Playfair
/// Display above the body tiers, Source Serif 4 everywhere else, including
/// `titleSmall` and below so buttons and labels stay out of a display face.
/// Both are bundled; see "The theme".
///
/// Every field and dropdown is outlined, so the border is here rather than at
/// each of them — see "The theme". A field passing its own still wins. The
/// radius reaches the same set: fields, dialogs, menus, sheets and buttons.
ThemeData entoliTheme(Brightness brightness, [AppLook look = entoliLook]) {
  final corners = BorderRadius.circular(look.radius);
  final shape = RoundedRectangleBorder(borderRadius: corners);
  final buttons = ButtonStyle(shape: WidgetStatePropertyAll(shape));
  final scheme = _scheme(brightness, look.primary, look.secondary);
  final text = _faceTextTheme(brightness, scheme);
  return ThemeData(
    colorScheme: scheme,
    textTheme: text,
    primaryTextTheme: text,
    inputDecorationTheme:
        InputDecorationTheme(border: OutlineInputBorder(borderRadius: corners)),
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

/// The default text theme with the bundled faces on it: Source Serif 4 on
/// every tier, then the display tiers — where a serif at 22pt reads as a
/// heading rather than as prose — on Playfair Display. The base is the same
/// `material2021` theme `ThemeData` builds for the scheme, so the geometry
/// (sizes, weights, letter-spacing) stays Material's and only the face moves.
TextTheme _faceTextTheme(Brightness brightness, ColorScheme scheme) {
  final base = Typography.material2021(colorScheme: scheme);
  final text = brightness == Brightness.dark ? base.white : base.black;
  return text
      .apply(fontFamily: bodyFamily)
      .copyWith(
        displayLarge: text.displayLarge?.copyWith(fontFamily: displayFamily),
        displayMedium: text.displayMedium?.copyWith(fontFamily: displayFamily),
        displaySmall: text.displaySmall?.copyWith(fontFamily: displayFamily),
        headlineLarge: text.headlineLarge?.copyWith(fontFamily: displayFamily),
        headlineMedium: text.headlineMedium?.copyWith(fontFamily: displayFamily),
        headlineSmall: text.headlineSmall?.copyWith(fontFamily: displayFamily),
        titleLarge: text.titleLarge?.copyWith(fontFamily: displayFamily),
        titleMedium: text.titleMedium?.copyWith(fontFamily: displayFamily),
      );
}

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
