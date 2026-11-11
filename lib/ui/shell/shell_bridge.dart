import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app_command.dart";
import "../app_menu_bar.dart";
import "../command_intents.dart";
import "../commands.dart";
import "../chat/chat_page.dart";
import "shell_palette.dart";
import "shell_publisher.dart";
import "shell_sidebar.dart";
import "shell_window.dart";

/// The app under the native shell, in `AppShell`'s place: the Flutter half of
/// a window SwiftUI owns. It asks the Swift to take the window, sends it the
/// snapshots it draws, runs what it sends back, and draws the open
/// conversation, [ChatPage]. The shell's bars reach it, and every page over
/// it, as padding, so it scrolls under them: see [ShellInsets]. The pages it
/// pushes draw over it inside the same view. The commands and their keys attach here as they do to
/// `AppShell`, and the menu bar is still `AppMenuBar`.
class ShellBridge extends ConsumerStatefulWidget {
  const ShellBridge({super.key});

  @override
  ConsumerState<ShellBridge> createState() => _ShellBridgeState();
}

class _ShellBridgeState extends ConsumerState<ShellBridge> {
  late final CommandScope _scope = ref.read(commandScopeProvider);

  /// The window's, the sidebar's and the palette's snapshots, sent as they
  /// change.
  late final ShellPublisher _publisher;

  /// The bridge the shell's events reach, which is the last one mounted. A
  /// restart builds the next session's before it takes this one down, so the
  /// one going unbinds them only while they are still its own.
  static _ShellBridgeState? _listening;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
    _scope.attach(_commands);
    _listening = this;
    _bind(this);
    _publisher = ShellPublisher(
      ProviderScope.containerOf(context, listen: false),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _scope.detach(_commands);
    _publisher.close();
    if (identical(_listening, this)) {
      _listening = null;
      _bind(null);
    }
    super.dispose();
  }

  /// What the shell sends under no surface's name — the window's own, the
  /// sidebar's, the palette's — to [bridge], or to nothing. The surfaces'
  /// own go to the one on top of each, through `ShellSlots`.
  static void _bind(_ShellBridgeState? bridge) {
    WindowEvents.setUp(bridge == null ? null : WindowRunner(bridge.ref));
    SidebarIntents.setUp(
      bridge == null ? null : SidebarRunner(bridge.context, bridge.ref),
    );
    PaletteIntents.setUp(
      bridge == null ? null : PaletteRunner(bridge.context, bridge.ref),
    );
  }

  Commands _commands() => Commands.read(context, ref);

  /// The commands' keys, while the Flutter view has them; with the shell's
  /// own field focused they reach the menu bar instead. See `AppShell`.
  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final command = AppCommand.of(event);
    if (command == null) return false;
    return _commands().run(command).isAvailable;
  }

  @override
  Widget build(BuildContext context) => const AppMenuBar(child: ChatPage());
}
