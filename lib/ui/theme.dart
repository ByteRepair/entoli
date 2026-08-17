import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart" show rootBundle;

import "../domain/app_theme.dart";

/// The indigo the icon sits on. The copies in `assets/icons/`, the Android
/// drawable and `web/manifest.json` are this colour written again — there is no
/// generator, so changing it here does not move them.
const entoliIndigo = Color(0xFF4F46E5);

/// The face anything shown verbatim is set in — code, a chat id, a config
/// value, the arguments of a command waiting on approval. The name is the
/// `family` in pubspec's `fonts:` block and has to stay in step with it.
///
/// Bundled rather than the `monospace` alias, which resolves to whatever the
/// platform has: those four things are shown verbatim because their exact
/// characters matter, which is a poor thing to leave to the device.
const monoFamily = "RobotoMono";

/// Roboto Mono is under the SIL Open Font Licence, which asks for the licence
/// to travel with it. This is what puts it in front of a reader rather than
/// only in the repository — Flutter's own licence page reads the registry, so
/// the text ships whether or not the app has grown a page to show it yet.
///
/// Read lazily: the registry takes a stream and only drains it when something
/// asks, so a run that never opens a licence page never opens the file.
void registerBundledFontLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["RobotoMono"],
      await rootBundle.loadString("assets/fonts/OFL.txt"),
    );
  });
}

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
