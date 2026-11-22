import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/byte_repair.dart";
import "../../app/pages/welcome.dart" show WelcomeAppPage;
import "../app_pages.dart";
import "about_settings.dart";
import "agents_settings.dart";
import "browser_settings.dart";
import "byte_repair_settings.dart";
import "data_settings.dart";
import "general_settings.dart";
import "llm_settings.dart";
import "memory_settings.dart";
import "schema_view.dart";
import "settings_category.dart";
import "skills_settings.dart";
import "sync_settings.dart";
import "terminal_settings.dart";
import "voice_settings.dart";

/// What [category] draws, in either of Settings' layouts.
Widget settingsCategoryBody(SettingsCategory category, {Key? key}) =>
    switch (category) {
      SettingsCategory.general => GeneralSettings(key: key),
      SettingsCategory.llms => LlmSettings(key: key),
      SettingsCategory.images => ImageSettings(key: key),
      SettingsCategory.memory => MemorySettings(key: key),
      SettingsCategory.voice => VoiceSettings(key: key),
      SettingsCategory.agentBrowser => BrowserSettings(key: key),
      SettingsCategory.byteRepair => ByteRepairSettings(key: key),
      SettingsCategory.data => DataSettings(key: key),
      SettingsCategory.shortcuts => ShortcutsSettings(key: key),
      SettingsCategory.about => AboutSettings(key: key),
      SettingsCategory.welcome => Builder(
        key: key,
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => openAppPage(context, WelcomeAppPage(replay: true)),
            child: const Text("Take the Welcome Tour"),
          ),
        ),
      ),
      SettingsCategory.terminal => TerminalSettings(key: key),
      // Skills and Agents scroll their own list, to keep their footers
      // fixed to the bottom.
      SettingsCategory.skills => SkillsSettings(key: key),
      SettingsCategory.agents => AgentsSettings(key: key),
      SettingsCategory.sync => SyncSettings(key: key),
      _ => ListView(key: key, children: [SchemaSections(category.page)]),
    };

/// Whether [category] may not be left now: Byte Repair while its setup
/// runs.
bool settingsCategoryHeld(WidgetRef ref, SettingsCategory category) =>
    category == SettingsCategory.byteRepair &&
    ref.watch(byteRepairHeldProvider);
