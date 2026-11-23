import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/view/theme.dart";

import "../providers.dart";

/// What the app is drawn with: the settings resolved against the system's own
/// palette, so `main` watches one thing and the rule that an accent replaces
/// both colours is written once.
final appLookProvider = Provider<AppLook>((ref) {
  final accent = ref.watch(paletteAccentProvider);
  final settings = ref.watch(
    appSettingsProvider.select(
      (s) => (
        primary: s.primaryColour,
        secondary: s.secondaryColour,
        radius: s.cornerRadius,
      ),
    ),
  );
  return (
    primary: accent == null
        ? settings.primary.seed
        : (
            colour: Color(accent),
            variant: DynamicSchemeVariant.tonalSpot,
            grey: false,
          ),
    secondary: accent == null ? settings.secondary.seed : null,
    radius: settings.radius.radius,
  );
});
