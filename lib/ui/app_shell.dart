import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/builtin_project.dart";
import "chat/chat_page.dart";
import "shortcuts.dart";
import "sidebar/project_palette.dart";
import "sidebar/sidebar.dart";
import "widgets/nav_drawer.dart";

/// Responsive shell: sidebar + chat pane. On narrow screens the sidebar
/// collapses into a drawer the chat page carries.
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

  /// The [AppShortcut]s. A handler rather than a `Shortcuts` widget: those
  /// hear a key only while focus is below them, and with nothing in the shell
  /// focused it is the route's scope, which is above.
  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final shortcut = AppShortcut.of(event);
    if (shortcut == null) return false;
    // Not over a page pushed on top, the palette itself included.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    switch (shortcut) {
      case AppShortcut.projectPalette:
        showProjectPalette(context, ref);
      case AppShortcut.newChat:
        openNewChat(context, ref);
      case AppShortcut.newAnonymousChat:
        openNewChatIn(context, ref, const AnonymousProject().dir);
      case AppShortcut.newOmadaChat:
        openNewChatIn(context, ref, omadaBaseProject);
      case AppShortcut.togglePin:
        toggleOpenChatPin(ref);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= navBreakpoint;
        if (wide) {
          return Row(
            children: const [
              SizedBox(width: sidebarWidth, child: Sidebar()),
              VerticalDivider(width: 1),
              Expanded(child: ChatPage()),
            ],
          );
        }
        return const ChatPage(withDrawer: true);
      },
    );
  }
}
