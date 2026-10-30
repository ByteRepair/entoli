import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// Whether the platform's chord key is Cmd rather than Ctrl.
bool get appleKeyboard =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The app-wide shortcuts: what `AppShell` answers and what Settings >
/// Shortcuts lists, so the two cannot disagree. Every one is Ctrl (Cmd on
/// Apple's platforms) plus a letter, with Shift and Alt (Option) as given.
enum AppShortcut {
  projectPalette("Open project palette", LogicalKeyboardKey.keyK),
  newChat("New chat", LogicalKeyboardKey.keyN),
  newAnonymousChat("New anonymous chat", LogicalKeyboardKey.keyN, shift: true),
  newOmadaChat("New Omada chat", LogicalKeyboardKey.keyN, alt: true),
  togglePin("Pin or unpin the open chat", LogicalKeyboardKey.keyP);

  const AppShortcut(this.label, this.key, {this.shift = false, this.alt = false});

  final String label;
  final LogicalKeyboardKey key;
  final bool shift;
  final bool alt;

  /// The shortcut the keys held down with [event] make, if any. Exact on every
  /// modifier, so Ctrl+Shift+N is not also Ctrl+N.
  static AppShortcut? of(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final chord = appleKeyboard
        ? keys.isMetaPressed && !keys.isControlPressed
        : keys.isControlPressed && !keys.isMetaPressed;
    if (!chord) return null;
    for (final shortcut in values) {
      if (shortcut.key == event.logicalKey &&
          shortcut.shift == keys.isShiftPressed &&
          shortcut.alt == keys.isAltPressed) {
        return shortcut;
      }
    }
    return null;
  }

  /// The keys as they are printed on this platform's keyboard, in the order
  /// it names them.
  List<String> get keyCaps => appleKeyboard
      ? ["⌘", if (alt) "⌥", if (shift) "⇧", key.keyLabel]
      : ["Ctrl", if (alt) "Alt", if (shift) "Shift", key.keyLabel];
}
