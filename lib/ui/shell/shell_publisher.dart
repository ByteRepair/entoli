import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "shell_outbox.dart";
import "shell_palette.dart";
import "shell_sidebar.dart";
import "shell_window.dart";

/// Sends the snapshots of the concerns no surface owns — the window, the
/// sidebar, the palette — each time one changes, from listeners on the
/// container rather than from a widget's build.
///
/// A build waits for a frame, and on an iPhone the sidebar is on screen
/// exactly when the Flutter view is not: the collapsed split view takes the
/// view out of the window to show the list, the engine is paused, and no
/// frame comes until the user leaves the list — so a rename, a pin or a
/// delete made from it never reached it. A widget's own subscription would not
/// do either: it is paused wherever a page covers the conversation,
/// `TickerMode` being off there. A provider's listener is neither.
class ShellPublisher {
  ShellPublisher(ProviderContainer container) {
    final outbox = container.read(shellOutboxProvider);
    _sending = [
      container.listen<WindowSnapshot>(
        windowSnapshotProvider,
        (_, s) => outbox.window(s),
        fireImmediately: true,
      ),
      container.listen<SidebarSnapshot>(
        sidebarSnapshotProvider,
        (_, s) => outbox.sidebar(s),
        fireImmediately: true,
      ),
      container.listen<PaletteSnapshot>(
        paletteSnapshotProvider,
        (_, s) => outbox.palette(s),
        fireImmediately: true,
      ),
    ];
  }

  late final List<ProviderSubscription<Object?>> _sending;

  void close() {
    for (final sending in _sending) {
      sending.close();
    }
  }
}
