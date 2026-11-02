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
import "conversation_pane.dart";
import "shell_composer.dart";
import "shell_new_chat.dart";
import "shell_outbox.dart";
import "shell_palette.dart";
import "shell_routes.dart";
import "shell_sidebar.dart";
import "shell_turn.dart";
import "shell_voice.dart";
import "snapshots.dart";

/// The app under the native shell, in `AppShell`'s place: the Flutter half of
/// a window SwiftUI owns. It asks the Swift to take the window, sends it the
/// snapshots it draws, runs what it sends back, and draws [ConversationPane].
/// The shell's bars reach it, and every page over it, as padding: see
/// [ShellInsets]. The commands and their keys attach here as they do to
/// `AppShell`, and the menu bar is still `AppMenuBar`.
class ShellBridge extends ConsumerStatefulWidget {
  const ShellBridge({super.key});

  @override
  ConsumerState<ShellBridge> createState() => _ShellBridgeState();
}

class _ShellBridgeState extends ConsumerState<ShellBridge> {
  late final CommandScope _scope = ref.read(commandScopeProvider);

  late final ValueNotifier<EdgeInsets> _insets = ref.read(shellInsetsProvider);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
    _scope.attach(_commands);
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
    shellChannel.setMethodCallHandler(null);
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
        _insets.value = EdgeInsets.fromLTRB(
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
    final slots = ref.read(shellSlotsProvider);
    switch (intent.name) {
      case "sidebar":
        ref.read(sidebarShownProvider.notifier).set(intent.flag("shown"));
        return null;
      // The composer's own events, as `name` and `args` inside the intent's.
      case "composer":
        final args = (intent.args["args"] as Map<Object?, Object?>?) ?? {};
        return slots.composer?.handle(
          intent.string("name"),
          args.cast<String, Object?>(),
        );
      // The turn surface's, the same way.
      case "turn":
        final args = (intent.args["args"] as Map<Object?, Object?>?) ?? {};
        await ref
            .read(shellTurnSlotProvider)
            .current
            ?.handle(intent.string("name"), args.cast<String, Object?>());
        return null;
      // The new-chat screen's, the same way.
      case "newChatScreen":
        final args = (intent.args["args"] as Map<Object?, Object?>?) ?? {};
        ref
            .read(shellNewChatSlotProvider)
            .current
            ?.handle(intent.string("name"), args.cast<String, Object?>());
        return null;
      // Voice mode's controls, the same way.
      case "voice":
        final args = (intent.args["args"] as Map<Object?, Object?>?) ?? {};
        ref
            .read(shellVoiceSlotProvider)
            .current
            ?.handle(intent.string("name"), args.cast<String, Object?>());
        return null;
      // The palette's, the same way, answered with an error to show or null.
      case "palette":
        final args = (intent.args["args"] as Map<Object?, Object?>?) ?? {};
        return runPaletteIntent(
          context,
          ref,
          intent.string("name"),
          args.cast<String, Object?>(),
        );
      case "toolbar":
        slots.bar?.press(intent.string("id"));
        return null;
    }
    if (!mounted) return null;
    final sidebar = await runSidebarIntent(context, ref, intent);
    if (!sidebar.handled) logFailure("shell", "no intent ${intent.name}");
    return sidebar.answer;
  }

  @override
  Widget build(BuildContext context) => const AppMenuBar(
    child: Stack(
      children: [
        _WindowPublisher(),
        SidebarPublisher(),
        PalettePublisher(),
        Positioned.fill(child: ConversationPane()),
      ],
    ),
  );
}

/// How much of the Flutter view the shell's own bars cover: the toolbar above,
/// the composer below. Zero with no shell.
final shellInsetsProvider = Provider<ValueNotifier<EdgeInsets>>((ref) {
  final insets = ValueNotifier(EdgeInsets.zero);
  ref.onDispose(insets.dispose);
  return insets;
});

/// [shellInsetsProvider] as the padding of everything under [child], and the
/// margin every tooltip keeps. Above the Navigator, from
/// `MaterialApp.builder`: a page pushed over the conversation is the
/// Navigator's, not the bridge's, and its bar has to clear the toolbar as the
/// conversation does.
class ShellInsets extends ConsumerWidget {
  const ShellInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ValueListenableBuilder<EdgeInsets>(
        valueListenable: ref.watch(shellInsetsProvider),
        child: child,
        builder: (context, insets, child) {
          final media = MediaQuery.of(context);
          // A tooltip goes where the Flutter view has room for it, and the
          // view runs under the toolbar and the composer: so every tooltip is
          // kept off both, once, here.
          final tooltips = TooltipTheme.of(context);
          final margin = tooltips.margin?.resolve(TextDirection.ltr);
          return MediaQuery(
            data: media.copyWith(padding: insets, viewPadding: insets),
            child: TooltipTheme(
              data: tooltips.copyWith(
                margin: (margin ?? EdgeInsets.zero).copyWith(
                  top: (margin?.top ?? 0) + insets.top,
                  bottom: (margin?.bottom ?? 0) + insets.bottom,
                ),
              ),
              child: child!,
            ),
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
      valueListenable: ref.watch(shellRoutesProvider).covered,
      builder: (context, covered, _) {
        ref
            .read(shellOutboxProvider)
            .post(
              WindowSnapshot(
                covered: covered,
                sidebarShown: shown,
                appearance: switch (theme) {
                  AppTheme.system => null,
                  AppTheme.light => "light",
                  AppTheme.dark => "dark",
                },
              ),
            );
        return const SizedBox.shrink();
      },
    );
  }
}
