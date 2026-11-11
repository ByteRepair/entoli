import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter/widgets.dart";

import "../app/app_items.dart";
import "../core/platform/form_factor.dart";

export "../app/app_items.dart";

/// Whether the platform's chord key is Cmd rather than Ctrl.
bool get appleKeyboard => isApple;

/// Whether the menu bar is on screen whatever the user does, so a page it
/// opens needs no other way there. Not iPadOS's, which hides until asked for
/// and is not there at all without a pointer.
bool get menuBarAlwaysShown => defaultTargetPlatform == TargetPlatform.macOS;

/// An [AppItem]'s keys as the Flutter frontend hears and prints them.
extension AppItemKeys on AppItem {
  LogicalKeyboardKey? get logicalKey => switch (key?.char) {
    null => null,
    "," => LogicalKeyboardKey.comma,
    "." => LogicalKeyboardKey.period,
    final char => LogicalKeyboardKey.findKeyByKeyId(char.codeUnitAt(0)),
  };

  /// The keys, as a shortcut takes them; null for an item with none.
  SingleActivator? get activator => switch ((key, logicalKey)) {
    (final key?, final logical?) => SingleActivator(
      logical,
      meta: appleKeyboard,
      control: !appleKeyboard,
      shift: key.shift,
      alt: key.alt,
    ),
    _ => null,
  };

  /// The keys as they are printed on this platform's keyboard, in the order
  /// it names them.
  List<String> get keyCaps {
    final key = this.key!;
    final cap = logicalKey!.keyLabel;
    return appleKeyboard
        ? ["⌘", if (key.alt) "⌥", if (key.shift) "⇧", cap]
        : ["Ctrl", if (key.alt) "Alt", if (key.shift) "Shift", cap];
  }
}

/// The item the keys held down with [event] make, if any. Exact on every
/// modifier, so Ctrl+Shift+N is not also Ctrl+N.
AppItem? appItemOf(KeyEvent event) => appItems
    .where(
      (c) => c.activator?.accepts(event, HardwareKeyboard.instance) ?? false,
    )
    .firstOrNull;
