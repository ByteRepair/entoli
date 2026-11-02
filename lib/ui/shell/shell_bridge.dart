import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/app_theme.dart";
import "../../providers.dart";
import "../app_command.dart";
import "../app_menu_bar.dart";
import "../command_intents.dart";
import "../commands.dart";
import "../selection.dart";
import "../app_routes.dart";
import "../chat/chat_page.dart";
import "shell_outbox.dart";
import "shell_palette.dart";
import "shell_sidebar.dart";
import "shell_slots.dart";
import "snapshots.dart";

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

  /// The bridge the channel's handler is, which is the last one mounted. A
  /// restart builds the next session's before it takes this one down, so the
  /// one going clears the handler only while it is still its own.
  static _ShellBridgeState? _listening;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
    _scope.attach(_commands);
    _listening = this;
    shellChannel.setMethodCallHandler(_handle);
    // Once per process: the window stays the shell's across a restore's
    // restart, and a second start is answered with nothing to do.
    shellChannel
        .invokeMethod<void>("start")
        .catchError((Object e) => logFailure("shell", "start: $e"));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    _scope.detach(_commands);
    if (identical(_listening, this)) {
      _listening = null;
      shellChannel.setMethodCallHandler(null);
    }
    super.dispose();
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

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
    switch (call.method) {
      case "insets":
        double at(String key) => (args[key] as num? ?? 0).toDouble();
        shellInsets.value = EdgeInsets.fromLTRB(
          at("left"),
          at("top"),
          at("right"),
          at("bottom"),
        );
      case "intent":
        if (!mounted) return null;
        return _run(ShellIntent.fromMap(args));
    }
    return null;
  }

  /// What the user did in the shell, answered with what the Swift waits on:
  /// an error to show, or null.
  Future<Object?> _run(ShellIntent intent) async {
    // A surface's own, as its name and args inside the intent's: to the one
    // on screen.
    if (_surfaces[intent.name] case final concern?) {
      final own = intent.nested;
      return ref
          .read(shellSlotsProvider)
          .top(concern)
          ?.handle(own.name, own.args);
    }
    switch (intent.name) {
      case "sidebar":
        ref.read(sidebarShownProvider.notifier).set(intent.flag("shown"));
        return null;
      case "palette":
        return runPaletteIntent(context, ref, intent.nested);
    }
    return runSidebarIntent(context, ref, intent);
  }

  static final _surfaces = ShellConcern.values.asNameMap();

  @override
  Widget build(BuildContext context) => const AppMenuBar(
    child: Stack(
      children: [
        _WindowPublisher(),
        SidebarPublisher(),
        PalettePublisher(),
        Positioned.fill(child: ChatPage()),
      ],
    ),
  );
}

/// How much of the Flutter view the shell's own bars cover: the toolbar above,
/// the composer below. Zero with no shell. The process's rather than a
/// session's, as the window is: the Swift says it only when it changes, so a
/// restart's session would otherwise start at zero and stay there, the
/// conversation under the bars.
final shellInsets = ValueNotifier(EdgeInsets.zero);

/// [shellInsets] as the padding of everything under [child]. Above
/// the Navigator, from `MaterialApp.builder`: a page pushed over the
/// conversation is the Navigator's, not the bridge's, and its bar has to
/// clear the toolbar as the conversation does.
class ShellInsets extends StatelessWidget {
  const ShellInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
    valueListenable: shellInsets,
    child: child,
    builder: (context, insets, child) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(padding: insets, viewPadding: insets),
        child: child!,
      );
    },
  );
}

/// Sends the [WindowSnapshot]. A widget of its own, like every publisher, so
/// what it watches rebuilds it and nothing else.
class _WindowPublisher extends ConsumerWidget {
  const _WindowPublisher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appSettingsProvider.select((s) => s.appTheme));
    final shown = ref.watch(sidebarShownProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: ref.watch(appRoutesProvider).covered,
      builder: (context, covered, _) {
        ref
            .read(shellOutboxProvider)
            .post(
              WindowSnapshot(
                covered: covered,
                sidebarShown: shown,
                appearance: theme == AppTheme.system ? null : theme.name,
              ),
            );
        return const SizedBox.shrink();
      },
    );
  }
}
