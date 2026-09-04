import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../providers.dart";
import "chat/chat_page.dart";
import "settings/welcome_page.dart";
import "sidebar/sidebar.dart";
import "widgets/nav_drawer.dart";

/// Responsive shell: sidebar + chat pane. On narrow screens the sidebar
/// collapses into a drawer the chat page carries. First launch is met with
/// the welcome tour over it.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
  }

  void _maybeWelcome() {
    if (!mounted || ref.read(appSettingsProvider).welcomeSeen) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WelcomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= navBreakpoint;
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
