import "../../app/pages/welcome.dart" show WelcomeAppPage;
import "../app_pages.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/settings.dart" show pageOffered;
import "../../app/settings/spec.dart";
import "../widgets/native_surfaces.dart";

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
  general(SettingsPageId.general, Icons.tune),
  providers(SettingsPageId.providers, Icons.cloud_outlined),
  onDevice(SettingsPageId.onDevice, Icons.memory),
  llms(SettingsPageId.llms, Icons.auto_awesome_outlined),
  images(SettingsPageId.images, Icons.image_outlined),
  memory(SettingsPageId.memory, Icons.psychology),
  voice(SettingsPageId.voice, Icons.graphic_eq),
  triggers(SettingsPageId.triggers, Icons.alarm),
  agents(SettingsPageId.agents, Icons.person_outline),
  skills(SettingsPageId.skills, Icons.extension),
  terminal(SettingsPageId.terminal, Icons.terminal),
  agentBrowser(SettingsPageId.agentBrowser, Icons.travel_explore),
  byteRepair(SettingsPageId.byteRepair, Icons.verified_user),
  sync(SettingsPageId.sync, Icons.sync),
  data(SettingsPageId.data, Icons.inventory_2_outlined),
  welcome(SettingsPageId.welcome, Icons.waving_hand),
  shortcuts(SettingsPageId.shortcuts, Icons.keyboard_outlined),
  about(SettingsPageId.about, Icons.info_outline);

  const SettingsCategory(this.page, this.icon);

  /// The schema's page it shows: its title, its group, and what is on it.
  final SettingsPageId page;
  final IconData icon;

  String get label => page.title;

  /// A divider drawn above the category's tile, where one group of categories
  /// ends and another begins.
  bool get dividerAbove => page.groupStart;

  /// Whether this platform can do anything the category sets. One it cannot
  /// is neither listed nor opened, so its page never has to say so.
  bool offered(WidgetRef ref) => pageOffered(WidgetReader(ref), page);
}

/// The route Settings is reached by, registered once with the app's
/// `MaterialApp` (`appRoute`): a page that opens Settings — the welcome tour,
/// which Settings itself shows as a category — names it here rather than
/// building the page.
const settingsRoute = "/settings";

/// What [settingsRoute] opens at: [category] alone where [focus], the way a
/// setup row or a bar points at one thing to set.
typedef SettingsArgs = ({SettingsCategory? category, bool focus});

/// Open Settings, at [category] where there is one: the native settings
/// where the frontend has its own, Flutter's page otherwise. The welcome tour
/// is not settings, and is Flutter's on every frontend.
Future<void> openSettings(
  BuildContext context, {
  SettingsCategory? category,
  bool focus = false,
}) {
  // The tour is a page of the app's, not a settings page.
  if (category == SettingsCategory.welcome) {
    openAppPage(context, WelcomeAppPage(replay: true));
    return Future.value();
  }
  if (nativeSurfacesOf(context) case final native?) {
    return native.openSettings(category?.page);
  }
  return Navigator.of(
    context,
  ).pushNamed(settingsRoute, arguments: (category: category, focus: focus));
}
