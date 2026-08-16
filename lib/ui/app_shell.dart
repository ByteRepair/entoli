import "package:flutter/material.dart";

import "chat/chat_page.dart";
import "sidebar/sidebar.dart";

/// Responsive shell: sidebar + chat pane. On narrow screens the sidebar
/// collapses into a drawer the chat page carries.
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        if (wide) {
          return Row(
            children: const [
              SizedBox(width: 280, child: Sidebar()),
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