import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "chat/chat_page.dart";
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

  /// Ctrl+K, or Cmd+K on Apple's platforms, opens the project palette. A
  /// handler rather than a `Shortcuts` widget: those hear a key only while
  /// focus is below them, and with nothing in the shell focused it is the
  /// route's scope, which is above.
  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyK) {
      return false;
    }
    final keys = HardwareKeyboard.instance;
    final apple = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final chord = apple
        ? keys.isMetaPressed && !keys.isControlPressed
        : keys.isControlPressed && !keys.isMetaPressed;
    if (!chord || keys.isShiftPressed || keys.isAltPressed) return false;
    // Not over a page pushed on top, the palette itself included.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    showProjectPalette(context, ref);
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
