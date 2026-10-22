import "package:flutter/services.dart";

import "../../../domain/agent_browser.dart";

/// The keys that insert nothing, or something other than their label, by the
/// DOM's names for them and the legacy code pages still read.
final Map<LogicalKeyboardKey, (String key, String code, int keyCode, String? text)>
    _named = {
  LogicalKeyboardKey.enter: ("Enter", "Enter", 13, "\r"),
  LogicalKeyboardKey.numpadEnter: ("Enter", "NumpadEnter", 13, "\r"),
  LogicalKeyboardKey.backspace: ("Backspace", "Backspace", 8, null),
  LogicalKeyboardKey.tab: ("Tab", "Tab", 9, null),
  LogicalKeyboardKey.escape: ("Escape", "Escape", 27, null),
  LogicalKeyboardKey.delete: ("Delete", "Delete", 46, null),
  LogicalKeyboardKey.space: (" ", "Space", 32, " "),
  LogicalKeyboardKey.arrowLeft: ("ArrowLeft", "ArrowLeft", 37, null),
  LogicalKeyboardKey.arrowUp: ("ArrowUp", "ArrowUp", 38, null),
  LogicalKeyboardKey.arrowRight: ("ArrowRight", "ArrowRight", 39, null),
  LogicalKeyboardKey.arrowDown: ("ArrowDown", "ArrowDown", 40, null),
  LogicalKeyboardKey.home: ("Home", "Home", 36, null),
  LogicalKeyboardKey.end: ("End", "End", 35, null),
  LogicalKeyboardKey.pageUp: ("PageUp", "PageUp", 33, null),
  LogicalKeyboardKey.pageDown: ("PageDown", "PageDown", 34, null),
  LogicalKeyboardKey.shiftLeft: ("Shift", "ShiftLeft", 16, null),
  LogicalKeyboardKey.shiftRight: ("Shift", "ShiftRight", 16, null),
  LogicalKeyboardKey.controlLeft: ("Control", "ControlLeft", 17, null),
  LogicalKeyboardKey.controlRight: ("Control", "ControlRight", 17, null),
  LogicalKeyboardKey.altLeft: ("Alt", "AltLeft", 18, null),
  LogicalKeyboardKey.altRight: ("Alt", "AltRight", 18, null),
  LogicalKeyboardKey.metaLeft: ("Meta", "MetaLeft", 91, null),
  LogicalKeyboardKey.metaRight: ("Meta", "MetaRight", 91, null),
};

/// The editing command a shortcut stands for. A synthesized key runs none on
/// its own, so it is named alongside. Paste is not here: the page's clipboard
/// is not the user's, so the card inserts the user's clipboard instead.
String? _command(String letter, {required bool shift}) => switch (letter) {
      "a" => "selectAll",
      "c" => "copy",
      "x" => "cut",
      "z" => shift ? "redo" : "undo",
      "y" => "redo",
      _ => null,
    };

/// The DOM's modifier bits for what is held: 1 Alt, 2 Ctrl, 4 Meta, 8 Shift.
int browserModifiers({
  required bool alt,
  required bool control,
  required bool meta,
  required bool shift,
}) =>
    (alt ? 1 : 0) | (control ? 2 : 0) | (meta ? 4 : 0) | (shift ? 8 : 0);

/// A key press as the page should receive it, or null for one it has no name
/// for. [shortcut] is whether the platform's shortcut modifier is held — Ctrl,
/// or Cmd on a Mac — which turns a letter into a command rather than text.
BrowserKey? browserKeyDown(
  KeyEvent event, {
  required int modifiers,
  required bool shortcut,
}) {
  final named = _named[event.logicalKey];
  if (named != null) {
    final (key, code, keyCode, text) = named;
    return BrowserKey(
      down: true,
      key: key,
      code: code,
      keyCode: keyCode,
      text: shortcut ? null : text,
      modifiers: modifiers,
    );
  }
  final character = event.character;
  if (character == null || character.isEmpty || character.codeUnitAt(0) < 32) {
    // Ctrl held makes some platforms report a control character; the key's
    // label is still the letter.
    final label = event.logicalKey.keyLabel;
    if (label.length != 1) return null;
    return _printable(label.toLowerCase(), modifiers: modifiers, shortcut: true,
        shift: modifiers & 8 != 0);
  }
  return _printable(character,
      modifiers: modifiers, shortcut: shortcut, shift: modifiers & 8 != 0);
}

BrowserKey _printable(
  String character, {
  required int modifiers,
  required bool shortcut,
  required bool shift,
}) {
  final upper = character.toUpperCase();
  final letter = RegExp(r"^[A-Z]$").hasMatch(upper);
  final digit = RegExp(r"^[0-9]$").hasMatch(character);
  final command = shortcut ? _command(character.toLowerCase(), shift: shift) : null;
  return BrowserKey(
    down: true,
    key: character,
    code: letter
        ? "Key$upper"
        : digit
            ? "Digit$character"
            : "",
    keyCode: letter || digit ? upper.codeUnitAt(0) : 0,
    text: shortcut ? null : character,
    modifiers: modifiers,
    commands: [?command],
  );
}

/// The release of a press: the same key, inserting nothing.
BrowserKey browserKeyUp(BrowserKey down, {required int modifiers}) => BrowserKey(
      down: false,
      key: down.key,
      code: down.code,
      keyCode: down.keyCode,
      modifiers: modifiers,
    );
