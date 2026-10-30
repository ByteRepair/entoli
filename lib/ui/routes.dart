import "package:flutter/material.dart";

import "settings/settings_category.dart";
import "settings/settings_page.dart";

/// The pages reached by name rather than built where they are opened: those
/// a page they contain opens again, so the two do not depend on each other.
/// Every `MaterialApp` the app is drawn in takes this.
Route<void>? appRoute(RouteSettings settings) => switch (settings.name) {
  settingsRoute => MaterialPageRoute(
    settings: settings,
    builder: (_) {
      final args = settings.arguments as SettingsArgs?;
      return SettingsPage(
        initialCategory: args?.category,
        focus: args?.focus ?? false,
      );
    },
  ),
  _ => null,
};
