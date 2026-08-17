import "package:flutter/material.dart";

import "../domain/app_theme.dart";

/// The indigo the icon sits on. The copies in `assets/icons/`, the Android
/// drawable and `web/manifest.json` are this colour written again — there is no
/// generator, so changing it here does not move them.
const entoliIndigo = Color(0xFF4F46E5);

/// The app's palette, in the brightness asked for.
ThemeData entoliTheme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: entoliIndigo,
        brightness: brightness,
      ),
    );

extension AppThemeMode on AppTheme {
  ThemeMode get mode => switch (this) {
        AppTheme.system => ThemeMode.system,
        AppTheme.light => ThemeMode.light,
        AppTheme.dark => ThemeMode.dark,
      };
}
