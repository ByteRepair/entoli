import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// One of the surfaces the native shell draws for a page — the composer, the
/// turn surface, the new-chat screen, voice mode, the chat's title bar, a
/// page's — as a stack of the widgets that draw it, [T] being the intents the
/// surface sends. The one on top is the one on screen, and the one the
/// shell's intents reach: voice mode's turn surface is over the chat page's,
/// and when it goes the chat page's is on top again.
class ShellSlot<T extends Object> {
  ShellSlot._(this._answer);

  /// Points the surface's intents at [T], or at nothing.
  final void Function(T?) _answer;
  final List<T> _stack = [];

  T? get top => _stack.lastOrNull;

  /// Put [surface] on top: where it mounts, or each time it is built where
  /// the last one built is the one on screen.
  void claim(T surface) {
    if (_stack.lastOrNull == surface) return;
    _stack
      ..remove(surface)
      ..add(surface);
    _answer(surface);
  }

  /// Take [surface] off. Answers whether it was on top, and so has what the
  /// shell draws for it to take back.
  bool leave(T surface) {
    final wasTop = _stack.lastOrNull == surface;
    _stack.remove(surface);
    if (wasTop) _answer(top);
    return wasTop;
  }
}

/// Every surface's stack. The intents of each go to the top of its own.
class ShellSlots {
  ShellSlots() {
    _live = this;
  }

  /// The last made, whose surfaces answer. A restart builds the next
  /// session's before it takes this one down, so the one going must not
  /// point an intent back at a surface of its own.
  static ShellSlots? _live;

  late final composer = _slot<ComposerIntents>(ComposerIntents.setUp);
  late final turn = _slot<TurnIntents>(TurnIntents.setUp);
  late final newChat = _slot<NewChatIntents>(NewChatIntents.setUp);
  late final voice = _slot<VoiceIntents>(VoiceIntents.setUp);
  late final chatBar = _slot<TitleBarIntents>(
    (surface) =>
        TitleBarIntents.setUp(surface, messageChannelSuffix: "chatBar"),
  );
  late final pageBar = _slot<TitleBarIntents>(
    (surface) =>
        TitleBarIntents.setUp(surface, messageChannelSuffix: "pageBar"),
  );

  ShellSlot<T> _slot<T extends Object>(void Function(T?) setUp) =>
      ShellSlot._((surface) {
        if (identical(_live, this)) setUp(surface);
      });
}

final shellSlotsProvider = Provider<ShellSlots>((ref) => ShellSlots());
