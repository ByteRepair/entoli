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
  ShellPublisher(ProviderContainer container)
    : _sending = [
        _send<WindowSnapshot>(
          container,
          windowSnapshotProvider,
          (o, s) => o.window(s),
        ),
        _send<SidebarSnapshot>(
          container,
          sidebarSnapshotProvider,
          (o, s) => o.sidebar(s),
        ),
        _send<PaletteSnapshot>(
          container,
          paletteSnapshotProvider,
          (o, s) => o.palette(s),
        ),
      ];

  final List<ProviderSubscription<Object?>> _sending;

  static ProviderSubscription<T> _send<T>(
    ProviderContainer container,
    Provider<T> snapshot,
    void Function(ShellOutbox, T) post,
  ) => container.listen(
    snapshot,
    (_, value) => post(container.read(shellOutboxProvider), value),
    fireImmediately: true,
  );

  void close() {
    for (final sending in _sending) {
      sending.close();
    }
  }
}
