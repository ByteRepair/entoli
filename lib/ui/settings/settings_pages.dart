import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/pages/welcome.dart" show WelcomeAppPage;
import "../../app/settings/settings.dart" show settingsPageHeldProvider;
import "../app_pages.dart";
import "schema_view.dart";
import "settings_category.dart";

/// What [category] draws, in either of Settings' layouts.
Widget settingsCategoryBody(SettingsCategory category, {Key? key}) =>
    switch (category) {
      SettingsCategory.welcome => Builder(
        key: key,
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => openAppPage(context, WelcomeAppPage(replay: true)),
            child: const Text("Take the Welcome Tour"),
          ),
        ),
      ),
      _ => ListView(key: key, children: [SchemaSections(category.page)]),
    };

/// Whether [category] may not be left now: Byte Repair while its setup
/// runs.
bool settingsCategoryHeld(WidgetRef ref, SettingsCategory category) =>
    ref.watch(settingsPageHeldProvider(category.page));
