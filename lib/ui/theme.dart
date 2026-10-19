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
    primary: accent == null
        ? settings.primary.seed
        : (colour: Color(accent), variant: DynamicSchemeVariant.tonalSpot, grey: false),
    secondary: accent == null ? settings.secondary.seed : null,
    radius: settings.radius.radius,
  );
});

/// A colour, how a scheme is built from it, and whether its surfaces are grey
/// rather than tinted with it — which only a primary decides.
typedef Seed = ({Color colour, DynamicSchemeVariant variant, bool grey});

/// A seed, the seed of the accent group beside it, and how round a corner is.
typedef AppLook = ({Seed primary, Seed? secondary, double radius});

/// What `ThemeColour.apple.seed` resolves to, the default, spelled out because
/// a getter cannot be const.
const entoliLook = (
  primary: (
    colour: Color(appleBlueArgb),
    variant: DynamicSchemeVariant.fidelity,
    grey: true,
  ),
  secondary: null,
  radius: 12.0,
);

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
ColorScheme _scheme(Brightness brightness, Seed primary, Seed? secondary) {
  var scheme = ColorScheme.fromSeed(
      seedColor: primary.colour,
      brightness: brightness,
      dynamicSchemeVariant: primary.variant);
  if (primary.grey) scheme = _greySurfaces(scheme, brightness);
  if (secondary == null || secondary == primary) return scheme;
  final accent = ColorScheme.fromSeed(
      seedColor: secondary.colour,
      brightness: brightness,
      dynamicSchemeVariant: secondary.variant);
  return scheme.copyWith(
    secondary: accent.secondary,
    onSecondary: accent.onSecondary,
    secondaryContainer: accent.secondaryContainer,
    onSecondaryContainer: accent.onSecondaryContainer,
  );
}

/// [scheme] with every neutral role taken from a monochrome one, whose
/// surfaces and outlines have no chroma at all. The accent roles are left as
/// they were.
ColorScheme _greySurfaces(ColorScheme scheme, Brightness brightness) {
  final grey = ColorScheme.fromSeed(
      seedColor: scheme.primary,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome);
  return scheme.copyWith(
    surface: grey.surface,
    onSurface: grey.onSurface,
    onSurfaceVariant: grey.onSurfaceVariant,
    surfaceDim: grey.surfaceDim,
    surfaceBright: grey.surfaceBright,
    surfaceContainerLowest: grey.surfaceContainerLowest,
    surfaceContainerLow: grey.surfaceContainerLow,
    surfaceContainer: grey.surfaceContainer,
    surfaceContainerHigh: grey.surfaceContainerHigh,
    surfaceContainerHighest: grey.surfaceContainerHighest,
    outline: grey.outline,
    outlineVariant: grey.outlineVariant,
    inverseSurface: grey.inverseSurface,
    onInverseSurface: grey.onInverseSurface,
  );
}

/// The scheme's own foreground for [fill], paired the way Material pairs its
/// roles, so text on it gets the contrast the scheme was built with whatever
/// the seed — a bold seed's container is the seed itself, which `onSurface`
/// can be unreadable on. A fill that is no role gets black or white by its
/// brightness.
Color onFill(ColorScheme s, Color fill) {
  final pairs = {
    s.primary: s.onPrimary,
    s.primaryContainer: s.onPrimaryContainer,
    s.secondary: s.onSecondary,
    s.secondaryContainer: s.onSecondaryContainer,
    s.tertiary: s.onTertiary,
    s.tertiaryContainer: s.onTertiaryContainer,
    s.error: s.onError,
    s.errorContainer: s.onErrorContainer,
    s.surface: s.onSurface,
    s.surfaceContainerLowest: s.onSurface,
    s.surfaceContainerLow: s.onSurface,
    s.surfaceContainer: s.onSurface,
    s.surfaceContainerHigh: s.onSurface,
    s.surfaceContainerHighest: s.onSurface,
    s.inverseSurface: s.onInverseSurface,
  };
  return pairs[fill] ??
      (ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
          ? Colors.white
          : Colors.black);
}

/// [theme] for what is drawn on [fill]: its text, and the links and caret
/// that take `primary`, in [onFill]'s colour. What paints its own surface —
/// code, which names `onSurface` — is left as it was.
ThemeData onFillTheme(ThemeData theme, Color fill) {
  final fg = onFill(theme.colorScheme, fill);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(bodyColor: fg, displayColor: fg),
    colorScheme: theme.colorScheme.copyWith(primary: fg),
  );
}

extension ThemeColourValue on ThemeColour {
  Color get colour => Color(argb);

  /// Fidelity keeps the seed's chroma, so a bold colour stays bold; the
  /// default softens it, which is what a pastel is.
  Seed get seed => (
        colour: colour,
        variant: group.vivid
            ? DynamicSchemeVariant.fidelity
            : DynamicSchemeVariant.tonalSpot,
        grey: greySurfaces,
      );
}

extension AppThemeMode on AppTheme {
  ThemeMode get mode => switch (this) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      };
}
