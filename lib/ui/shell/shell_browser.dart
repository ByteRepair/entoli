import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform;
import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/agent_browser.dart";
import "../chat/widgets/browser_input.dart";
import "shell_answers.dart";
import "shell_outbox.dart";

/// The agent's browser as the native shell shows it, in place of the
/// Flutter `BrowserCard`: the page's title and address and whether the agent
/// is held off it, sent as a [BrowserViewSnapshot] as they change; its
/// frames, as they come; and what the user does in the view — the browser's
/// own back, forward and reload, the mouse, the keys — run on the tab. A key
/// arrives as the platform's own and is read as a Flutter key, so
/// [browserKeyDown] is the one mapping to the page's keys.
class BrowserWindowSession implements BrowserIntents {
  BrowserWindowSession({
    required this.tab,
    required this.outbox,
    required this.answers,
    required this.onQuit,
    required this.windowed,
    required this.onClose,
  }) {
    answers.browser.take(this);
    tab.page.addListener(_publish);
    tab.hold.addListener(_publish);
    _follow();
    tab.page.addListener(_follow);
    _publish();
  }

  final BrowserTab tab;
  final ShellOutbox outbox;
  final ShellAnswers answers;
  final Future<void> Function() onQuit;

  /// Whether the page can open in a window of the browser's own.
  final bool windowed;

  /// Run when the user closes the view: its owner lets this go.
  final void Function() onClose;

  StreamSubscription<BrowserFrame>? _frames;
  Object? _opened;
  bool _closed = false;

  /// The presses still held, by key code, so a release names the key its
  /// press did.
  final _held = <int, BrowserKey>{};

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  void _publish() {
    if (_closed) return;
    final page = tab.page.value;
    outbox.browser(
      BrowserViewSnapshot(
        present: true,
        title: page == null || page.title.isEmpty ? "Browser" : page.title,
        url: page?.url,
        open: page != null,
        hidden: tab.hold.value != null,
        window: windowed,
      ),
    );
  }

  /// A new tab under the same chat is a new stream to listen to.
  void _follow() {
    final opened = tab.page.value?.opened;
    if (opened == _opened && _frames != null) return;
    _opened = opened;
    _frames?.cancel();
    _frames = tab.frames().listen(
      (frame) => outbox.browserFrame(
        BrowserFrameSnapshot(
          jpeg: frame.jpeg,
          width: frame.width,
          height: frame.height,
        ),
      ),
      onError: (Object e) => logFailure("browser", "frames stopped", e),
    );
  }

  /// Fires [send], saying in the log rather than on screen when it fails:
  /// the next frame shows whether it landed.
  void _send(Future<void> Function() send) => unawaited(
    send().catchError((Object e) {
      logFailure("browser", "input to the page failed", e);
    }),
  );

  @override
  void close() => onClose();

  @override
  void back() => _send(tab.historyBack);

  @override
  void forward() => _send(tab.forward);

  @override
  void reload() => _send(tab.reload);

  @override
  void window() => _send(tab.show);

  @override
  void hide() => tab.hide(const BrowserHold());

  @override
  void unhide() => tab.unhide();

  @override
  void quit() => _send(onQuit);

  @override
  void pointer(
    BrowserPointerAction action,
    double x,
    double y,
    String button,
    int buttons,
    int clickCount,
    double deltaX,
    double deltaY,
    int modifiers,
  ) => _send(
    () => tab.pointer(
      BrowserPointer(
        switch (action) {
          BrowserPointerAction.move => BrowserPointerKind.move,
          BrowserPointerAction.down => BrowserPointerKind.down,
          BrowserPointerAction.up => BrowserPointerKind.up,
          BrowserPointerAction.wheel => BrowserPointerKind.wheel,
        },
        x: x,
        y: y,
        button: button,
        buttons: buttons,
        clickCount: clickCount,
        deltaX: deltaX,
        deltaY: deltaY,
        modifiers: modifiers,
      ),
    ),
  );

  /// The platform's key, read as Flutter reads it: paste is the user's
  /// clipboard, copy and cut fill it and still reach the page, and every
  /// other key is the page's.
  @override
  void key(bool down, int keyCode, String? characters, int modifiers) {
    if (!down) {
      final pressed = _held.remove(keyCode);
      if (pressed != null) {
        _send(() => tab.key(browserKeyUp(pressed, modifiers: modifiers)));
      }
      return;
    }
    final event = _flutterKey(keyCode, characters);
    if (event == null) return;
    final shortcut = _mac ? modifiers & 4 != 0 : modifiers & 2 != 0;
    if (shortcut && event.logicalKey == LogicalKeyboardKey.keyV) {
      return edit(BrowserEdit.paste);
    }
    if (shortcut &&
        (event.logicalKey == LogicalKeyboardKey.keyC ||
            event.logicalKey == LogicalKeyboardKey.keyX)) {
      _send(tab.copySelection);
    }
    final pressed = browserKeyDown(
      event,
      modifiers: modifiers,
      shortcut: shortcut,
    );
    if (pressed == null) return;
    _held[keyCode] = pressed;
    _send(() => tab.key(pressed));
  }

  /// [keyCode] as the platform's key tables name it, with the characters it
  /// typed.
  static KeyDownEvent? _flutterKey(int keyCode, String? characters) {
    final physical = _mac
        ? kMacOsToPhysicalKey[keyCode]
        : kIosToPhysicalKey[keyCode];
    final character = characters != null && characters.isNotEmpty
        ? characters
        : null;
    final logical =
        (_mac ? kMacOsToLogicalKey[keyCode] : kIosToLogicalKey[keyCode]) ??
        (character == null
            ? null
            : LogicalKeyboardKey(character.toLowerCase().codeUnitAt(0)));
    if (physical == null || logical == null) return null;
    return KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      character: character,
      timeStamp: Duration.zero,
    );
  }

  @override
  void edit(BrowserEdit action) {
    switch (action) {
      case BrowserEdit.paste:
        _send(tab.pasteClipboard);
      case BrowserEdit.copy:
        _send(tab.copySelection);
      case BrowserEdit.cut:
        _send(tab.copySelection);
        _send(() => tab.pressShortcut("x", mac: _mac));
      case BrowserEdit.selectAll:
        _send(() => tab.pressShortcut("a", mac: _mac));
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    tab.page.removeListener(_publish);
    tab.hold.removeListener(_publish);
    tab.page.removeListener(_follow);
    _frames?.cancel();
    if (answers.browser.release(this)) {
      outbox.browser(BrowserViewSnapshot());
    }
  }
}
