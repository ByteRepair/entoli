import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_theme.dart";
import "../../providers.dart";
import "../selection.dart";

/// The window as the shell draws it: whether the sidebar is shown, and the
/// appearance the user picked.
final windowSnapshotProvider = Provider<WindowSnapshot>((ref) {
  final theme = ref.watch(appSettingsProvider.select((s) => s.appTheme));
  return WindowSnapshot(
    sidebarShown: ref.watch(sidebarShownProvider),
    dark: theme == AppTheme.system ? null : theme == AppTheme.dark,
  );
});

/// The window's own events: the sidebar shown or hidden by the shell's own
/// control.
class WindowRunner implements WindowEvents {
  WindowRunner(this.ref);

  final WidgetRef ref;

  @override
  void sidebarShown(bool shown) =>
      ref.read(sidebarShownProvider.notifier).set(shown);
}
