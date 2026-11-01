import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "chat/chat_page.dart";
import "app_command.dart";
import "app_menu_bar.dart";
import "commands.dart";
import "sidebar/sidebar.dart";
import "selection.dart";
import "widgets/side_panel_frame.dart";

/// The sidebar and the chat pane, in a [SidePanelFrame]: beside each other
/// where the window is wide and the sidebar is shown, the sidebar a drawer
/// where it is narrow.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  /// The [AppCommand]s' keys. A handler rather than a `Shortcuts` widget:
  /// those hear a key only while focus is below them, and with nothing in the
  /// shell focused it is the route's scope, which is above. Where a menu bar
  /// holds the same keys, whichever hears one first runs it and the other
  /// never does.
  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final command = AppCommand.of(event);
    if (command == null) return false;
    return Commands.read(context, ref).run(command);
  }

  @override
  Widget build(BuildContext context) => AppMenuBar(
    child: SidePanelFrame(
      panel: const Sidebar(),
      panelWidth: sidebarWidth,
      shown: ref.watch(sidebarShownProvider),
      onShownChanged: ref.read(sidebarShownProvider.notifier).set,
      child: const ChatPage(),
    ),
  );
}
