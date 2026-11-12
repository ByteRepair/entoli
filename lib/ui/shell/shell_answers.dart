import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// Who answers one surface's intents: the widget drawing it now. One at a
/// time, since what is on screen is decided by the app's state — the
/// selection, whether voice mode is up — and not by which widget mounted
/// last.
class ShellAnswer<T extends Object> {
  ShellAnswer._(this._setUp);

  final void Function(T?) _setUp;
  T? _owner;

  T? get owner => _owner;

  void take(T surface) {
    if (identical(_owner, surface)) return;
    _owner = surface;
    _setUp(surface);
  }

  /// Let go, where [surface] was answering. Answers whether it was, and so
  /// has what the shell draws for it to take back.
  bool release(T surface) {
    if (!identical(_owner, surface)) return false;
    _owner = null;
    _setUp(null);
    return true;
  }
}

/// Every surface's answer.
class ShellAnswers {
  ShellAnswers() {
    _live = this;
  }

  /// The last made, whose surfaces answer. A restart builds the next
  /// session's before it takes this one down, so the one going must not
  /// point an intent back at a surface of its own.
  static ShellAnswers? _live;

  late final composer = _answer<ComposerIntents>(ComposerIntents.setUp);
  late final turn = _answer<TurnIntents>(TurnIntents.setUp);
  late final newChat = _answer<NewChatIntents>(NewChatIntents.setUp);
  late final voice = _answer<VoiceIntents>(VoiceIntents.setUp);
  late final chatBar = _answer<ChatBarIntents>(ChatBarIntents.setUp);
  late final transcript = _answer<TranscriptIntents>(TranscriptIntents.setUp);
  late final foot = _answer<ChatFootIntents>(ChatFootIntents.setUp);
  late final browser = _answer<BrowserIntents>(BrowserIntents.setUp);
  late final pageBar = _answer<TitleBarIntents>(
    (surface) =>
        TitleBarIntents.setUp(surface, messageChannelSuffix: "pageBar"),
  );

  /// Voice mode is on screen: its turn surface is the one drawn, the chat
  /// page's beneath it standing down until it goes.
  final ValueNotifier<bool> voiceOn = ValueNotifier(false);

  ShellAnswer<T> _answer<T extends Object>(void Function(T?) setUp) =>
      ShellAnswer._((surface) {
        if (identical(_live, this)) setUp(surface);
      });
}

final shellAnswersProvider = Provider<ShellAnswers>((ref) => ShellAnswers());
