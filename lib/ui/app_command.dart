import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter/widgets.dart";

/// Whether the platform's chord key is Cmd rather than Ctrl.
bool get appleKeyboard =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Whether this platform draws the app's menus: macOS's menu bar, and iPadOS's
/// over a channel of the app's own — which an iPhone answers with its keys.
bool get platformHasMenus => appleKeyboard;

/// Whether the menu bar is on screen whatever the user does, so a page it
/// opens needs no other way there. Not iPadOS's, which hides until asked for
/// and is not there at all without a pointer.
bool get menuBarAlwaysShown => defaultTargetPlatform == TargetPlatform.macOS;

/// Everything the app can be told to do by name, wherever it is told: a key,
/// a menu bar, and whatever else names one later. The name is the id, so it
/// is never renamed. What a command does is `Commands`; this is what it is
/// called and the keys it answers, so the menus and Settings > Shortcuts
/// cannot disagree. A key is Ctrl (Cmd on Apple's platforms) plus [key], with
/// Shift and Alt (Option) as given.
enum AppCommand {
  // The app's own pages: opened over whatever is on screen.
  about("About Entoli", anywhere: true),
  settings("Settings…", key: LogicalKeyboardKey.comma, anywhere: true),
  profile("Profile…", anywhere: true),
  marketplace("Marketplace…", anywhere: true),
  backUp("Back Up…", anywhere: true),
  welcome("Welcome Tour", anywhere: true),
  keyboardShortcuts("Keyboard Shortcuts", anywhere: true),

  // The rest act on the chat pane, so only while it is in front.
  newChat("New Chat", key: LogicalKeyboardKey.keyN),
  newAnonymousChat(
    "New Anonymous Chat",
    key: LogicalKeyboardKey.keyN,
    shift: true,
  ),
  newOmadaChat("New Omada Chat", key: LogicalKeyboardKey.keyN, alt: true),
  switchProject("Switch Project…", key: LogicalKeyboardKey.keyK),
  toggleSidebar("Toggle Sidebar", key: LogicalKeyboardKey.keyS, alt: true),

  pinChat("Pin Chat", key: LogicalKeyboardKey.keyP, shift: true),
  renameChat("Rename Chat…"),
  moveChat("Move Chat to Project…"),
  deleteChat("Delete Chat…"),
  chatSettings("Chat Settings…"),
  showPlan("Show Plan"),
  stopTurn("Stop Turn", key: LogicalKeyboardKey.period),

  projectWorkspace("Workspace"),
  projectMemories("Memories"),
  projectSettings("Project Settings…");

  const AppCommand(
    this.label, {
    this.key,
    this.shift = false,
    this.alt = false,
    this.anywhere = false,
  });

  final String label;
  final LogicalKeyboardKey? key;
  final bool shift;
  final bool alt;

  /// Runs with a page pushed over the chat pane. The rest would act on a pane
  /// nobody can see.
  final bool anywhere;

  /// The keys, as a menu takes them; null for a command with none.
  SingleActivator? get activator => key == null
      ? null
      : SingleActivator(
          key!,
          meta: appleKeyboard,
          control: !appleKeyboard,
          shift: shift,
          alt: alt,
        );

  /// The command the keys held down with [event] make, if any. Exact on every
  /// modifier, so Ctrl+Shift+N is not also Ctrl+N.
  static AppCommand? of(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final chord = appleKeyboard
        ? keys.isMetaPressed && !keys.isControlPressed
        : keys.isControlPressed && !keys.isMetaPressed;
    if (!chord) return null;
    for (final command in values) {
      if (command.key == event.logicalKey &&
          command.shift == keys.isShiftPressed &&
          command.alt == keys.isAltPressed) {
        return command;
      }
    }
    return null;
  }

  /// The keys as they are printed on this platform's keyboard, in the order
  /// it names them.
  List<String> get keyCaps => appleKeyboard
      ? ["⌘", if (alt) "⌥", if (shift) "⇧", key!.keyLabel]
      : ["Ctrl", if (alt) "Alt", if (shift) "Shift", key!.keyLabel];
}
