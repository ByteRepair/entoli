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
import "snapshots.dart";

/// Where the snapshots go: [send] once per change of a concern's map.
class ShellOutbox {
  ShellOutbox(this.send);

  /// Over [shellChannel], to the Swift.
  ShellOutbox.channel()
    : send = ((concern, map) => shellChannel.invokeMethod<void>("snapshot", {
        "concern": concern,
        "value": map,
      }));

  final void Function(String concern, Map<String, Object?> map) send;
  final Map<String, String> _sent = {};

  void post(ShellSnapshot snapshot) {
    final encoded = snapshot.encode();
    if (_sent[snapshot.concern] == encoded) return;
    _sent[snapshot.concern] = encoded;
    send(snapshot.concern, snapshot.toMap());
  }
}

final shellOutboxProvider = Provider<ShellOutbox>(
  (ref) => ShellOutbox.channel(),
);

/// Whether a page is pushed over the conversation. On the app's Navigator,
/// from `main`; only the shell reads it.
class ShellRoutes extends NavigatorObserver {
  final List<Route<Object?>> _stack = [];

  /// A page over the first route, which is the conversation's. A dialog is a
  /// route too and covers nothing: it draws over the Flutter view alone.
  final ValueNotifier<bool> covered = ValueNotifier(false);

  void _changed() =>
      covered.value = _stack.skip(1).any((route) => route is PageRoute);

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<Object?> route, Route<Object?>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<Object?>? newRoute, Route<Object?>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      at < 0 ? _stack.add(newRoute) : _stack[at] = newRoute;
    } else if (at >= 0) {
      _stack.removeAt(at);
    }
    _changed();
  }
}

final shellRoutesProvider = Provider<ShellRoutes>((ref) => ShellRoutes());

/// The app under the native shell, in `AppShell`'s place: the Flutter half of
/// a window SwiftUI owns. It asks the Swift to take the window, sends it the
/// snapshots it draws, runs what it sends back, and draws [ConversationPane]
/// with the shell's bars as its padding. The commands and their keys attach
/// here as they do to `AppShell`, and the menu bar is still `AppMenuBar`.
class ShellBridge extends ConsumerStatefulWidget {
  const ShellBridge({super.key});

  @override
  ConsumerState<ShellBridge> createState() => _ShellBridgeState();
}

class _ShellBridgeState extends ConsumerState<ShellBridge> {
  late final CommandScope _scope = ref.read(commandScopeProvider);

  /// How much of the Flutter view the shell's own bars cover: the toolbar
  /// above, the composer below.
  final ValueNotifier<EdgeInsets> _insets = ValueNotifier(EdgeInsets.zero);

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
    _insets.dispose();
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
        _run(ShellIntent.fromMap(args));
    }
    return null;
  }

  void _run(ShellIntent intent) {
    switch (intent.name) {
      case "sidebar":
        ref.read(sidebarShownProvider.notifier).set(intent.flag("shown"));
      default:
        logFailure("shell", "no intent ${intent.name}");
    }
  }

  @override
  Widget build(BuildContext context) => AppMenuBar(
    child: Stack(
      children: [
        const _WindowPublisher(),
        Positioned.fill(
          child: ValueListenableBuilder<EdgeInsets>(
            valueListenable: _insets,
            builder: (context, insets, child) {
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(padding: insets, viewPadding: insets),
                child: child!,
              );
            },
            child: const ConversationPane(),
          ),
        ),
      ],
    ),
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
