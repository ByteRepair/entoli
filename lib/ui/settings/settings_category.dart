import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";

/// The page's categories, in the order they are offered and the groups they
/// are offered in. General, Providers, On-device, LLMs and Image Generation
/// are the app and the plumbing that answers a chat — everything an endpoint
/// is, where a model can run without a network, and everything a model is
/// asked to do; Memory, Voice
/// and Triggers are what a conversation does beyond the text; Agents and
/// Skills are what a message addresses by name; Terminal, Agent Browser and
/// Byte Repair are where commands run and pages open; Sync and Data are the device and all of it at once —
/// the chats, the settings and the workspaces as one file to keep; and
/// Welcome, Shortcuts and About are the app rather than anything it does,
/// which is why they are last.
enum SettingsCategory {
  general("General", Icons.tune),
  providers("Providers", Icons.cloud_outlined),
  onDevice("On-device", Icons.memory),
  llms("LLMs", Icons.auto_awesome_outlined),
  images("Image Generation", Icons.image_outlined),
  memory("Memory", Icons.psychology, dividerAbove: true),
  voice("Voice", Icons.graphic_eq),
  triggers("Triggers", Icons.alarm),
  agents("Agents", Icons.person_outline, dividerAbove: true),
  skills("Skills", Icons.extension),
  terminal("Terminal", Icons.terminal, dividerAbove: true),
  agentBrowser("Agent Browser", Icons.travel_explore),
  byteRepair("Byte Repair", Icons.verified_user),
  sync("Sync", Icons.sync, dividerAbove: true),
  data("Data", Icons.inventory_2_outlined),
  welcome("Welcome", Icons.waving_hand, dividerAbove: true),
  shortcuts("Shortcuts", Icons.keyboard_outlined),
  about("About", Icons.info_outline);

  const SettingsCategory(this.label, this.icon, {this.dividerAbove = false});

  final String label;
  final IconData icon;

  /// A divider drawn above the category's tile, where one group of categories
  /// ends and another begins.
  final bool dividerAbove;

  /// Whether this platform can do anything the category sets. One it cannot
  /// is neither listed nor opened, so its page never has to say so. A
  /// category only part of which depends on the platform says so inside
  /// instead, as On-device does.
  bool offered(WidgetRef ref) => switch (this) {
        agentBrowser => ref.watch(agentBrowserProvider).available,
        voice => ref.watch(voiceProvider).available,
        triggers => ref.watch(reminderAlarmsProvider).available,
        _ => true,
      };
}

/// The route Settings is reached by, registered once with the app's
/// `MaterialApp` (`appRoute`): a page that opens Settings — the welcome tour,
/// which Settings itself shows as a category — names it here rather than
/// building the page.
const settingsRoute = "/settings";

/// What [settingsRoute] opens at: [category] alone where [focus], the way a
/// setup row or a bar points at one thing to set.
typedef SettingsArgs = ({SettingsCategory? category, bool focus});

/// Open Settings, at [category] where there is one.
Future<void> openSettings(BuildContext context,
        {SettingsCategory? category, bool focus = false}) =>
    Navigator.of(context).pushNamed(settingsRoute,
        arguments: (category: category, focus: focus));
