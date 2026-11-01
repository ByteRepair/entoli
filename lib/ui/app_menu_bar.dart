import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "app_command.dart";
import "commands.dart";

/// One menu of the bar: its commands in groups, and the platform's own items
/// after them.
class AppMenu {
  const AppMenu(this.label, this.groups, {this.system = const []});

  final String label;
  final List<List<AppCommand>> groups;

  /// Only macOS has any; elsewhere they are dropped.
  final List<PlatformProvidedMenuItemType> system;
}

/// The menu bar, as data. The first menu is the app's own, which macOS titles
/// with the app's name whatever this one says.
const List<AppMenu> appMenus = [
  AppMenu(
    "Entoli",
    [
      [AppCommand.about],
      [AppCommand.settings, AppCommand.profile, AppCommand.marketplace],
    ],
    system: [
      PlatformProvidedMenuItemType.servicesSubmenu,
      PlatformProvidedMenuItemType.hide,
      PlatformProvidedMenuItemType.hideOtherApplications,
      PlatformProvidedMenuItemType.showAllApplications,
      PlatformProvidedMenuItemType.quit,
    ],
  ),
  AppMenu("File", [
    [AppCommand.newChat, AppCommand.newAnonymousChat, AppCommand.newOmadaChat],
    [AppCommand.switchProject],
    [AppCommand.backUp],
  ]),
  AppMenu("Chat", [
    [AppCommand.pinChat, AppCommand.renameChat, AppCommand.moveChat],
    [AppCommand.chatSettings, AppCommand.showPlan, AppCommand.stopTurn],
    [AppCommand.deleteChat],
  ]),
  AppMenu("Project", [
    [
      AppCommand.projectWorkspace,
      AppCommand.projectMemories,
      AppCommand.projectSettings,
    ],
  ]),
  AppMenu(
    "View",
    [
      [AppCommand.toggleSidebar],
    ],
    system: [PlatformProvidedMenuItemType.toggleFullScreen],
  ),
  AppMenu(
    "Window",
    [],
    system: [
      PlatformProvidedMenuItemType.minimizeWindow,
      PlatformProvidedMenuItemType.zoomWindow,
      PlatformProvidedMenuItemType.arrangeWindowsInFront,
    ],
  ),
  AppMenu("Help", [
    [AppCommand.welcome, AppCommand.keyboardShortcuts],
  ]),
];

/// iPadOS has no menu bar in Flutter's engine, so its menus go over a channel
/// of the app's own, which `AppDelegate.swift` builds into UIKit's. The same
/// protocol as macOS's, so the menus above are drawn the same way on both.
void installMenuChannel() {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  WidgetsBinding.instance.platformMenuDelegate = DefaultPlatformMenuDelegate(
    channel: const MethodChannel("agent_chat/menu"),
  );
}

/// [appMenus] in the platform's menu bar, over [child]: greyed where a
/// command cannot run, each item running its command the way its keys do.
/// Nothing where the platform has no menus. Must sit below the Navigator, as
/// the commands open their pages from here.
class AppMenuBar extends ConsumerWidget {
  const AppMenuBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!platformHasMenus) return child;
    final commands = Commands.watch(context, ref);
    PlatformMenuItem item(AppCommand command) => PlatformMenuItem(
      label: commands.label(command),
      shortcut: command.activator,
      onSelected: commands.availability(command).isAvailable
          ? () => Commands.read(context, ref).run(command)
          : null,
    );
    List<PlatformMenuItem> members(AppMenu menu) {
      final system = [
        for (final type in menu.system)
          if (PlatformProvidedMenuItem.hasMenu(type))
            PlatformProvidedMenuItem(type: type),
      ];
      return [
        for (final group in menu.groups)
          PlatformMenuItemGroup(members: [for (final c in group) item(c)]),
        if (system.isNotEmpty) PlatformMenuItemGroup(members: system),
      ];
    }

    return PlatformMenuBar(
      menus: [
        for (final menu in appMenus)
          if (members(menu) case final items when items.isNotEmpty)
            PlatformMenu(label: menu.label, menus: items),
      ],
      child: child,
    );
  }
}
