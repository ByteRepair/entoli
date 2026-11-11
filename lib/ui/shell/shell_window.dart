import "dart:math" as math;

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_theme.dart";
import "../../providers.dart";
import "../app_routes.dart";
import "../bot_avatar/bot_avatar_view.dart" show setNativePointerPosition;
import "../selection.dart";

/// Whether a Flutter page covers the conversation, as a provider: the
/// routes say it as a listenable.
class _Covered extends Notifier<bool> with ListenableValue<bool> {
  @override
  bool build() => bridge(ref.watch(appRoutesProvider).covered);
}

final _coveredProvider = NotifierProvider<_Covered, bool>(_Covered.new);

/// The window as the shell draws it: whether a page covers the chat, whether
/// the sidebar is shown, and the appearance the user picked.
final windowSnapshotProvider = Provider<WindowSnapshot>((ref) {
  final theme = ref.watch(appSettingsProvider.select((s) => s.appTheme));
  return WindowSnapshot(
    covered: ref.watch(_coveredProvider),
    sidebarShown: ref.watch(sidebarShownProvider),
    dark: theme == AppTheme.system ? null : theme == AppTheme.dark,
  );
});

/// How much of the Flutter view the shell's own bars cover: the toolbar above,
/// the composer below, and below that the keyboard the composer rides on.
/// Zero with no shell. The process's rather than a
/// session's, as the window is: the Swift says it only when it changes, so a
/// restart's session would otherwise start at zero and stay there, the
/// conversation under the bars.
final shellInsets = ValueNotifier(EdgeInsets.zero);

/// [shellInsets] as the view padding of everything under [child], and the
/// padding less the view insets, as Flutter derives the system's: the
/// keyboard is in both, and a page is already shrunk by it. Above the Navigator, from
/// `MaterialApp.builder`: a page pushed over the conversation is the
/// Navigator's, not the bridge's, and its bar has to clear the toolbar as
/// the conversation does.
class ShellInsets extends StatelessWidget {
  const ShellInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
    valueListenable: shellInsets,
    child: child,
    builder: (context, insets, child) {
      final media = MediaQuery.of(context);
      final keyboard = media.viewInsets;
      return MediaQuery(
        data: media.copyWith(
          viewPadding: insets,
          padding: EdgeInsets.fromLTRB(
            math.max(0, insets.left - keyboard.left),
            math.max(0, insets.top - keyboard.top),
            math.max(0, insets.right - keyboard.right),
            math.max(0, insets.bottom - keyboard.bottom),
          ),
        ),
        child: child!,
      );
    },
  );
}

/// The window's own events: how far the shell's bars reach, the sidebar
/// shown or hidden by the shell's own control, and the pointer.
class WindowRunner implements WindowEvents {
  WindowRunner(this.ref);

  final WidgetRef ref;

  @override
  void insets(double left, double top, double right, double bottom) =>
      shellInsets.value = EdgeInsets.fromLTRB(left, top, right, bottom);

  @override
  void sidebarShown(bool shown) =>
      ref.read(sidebarShownProvider.notifier).set(shown);

  @override
  void pointer(double x, double y) => setNativePointerPosition(Offset(x, y));
}
