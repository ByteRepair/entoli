import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

/// Who answers one surface's intents: the widget drawing it now. One at a
/// time, since what is on screen is decided by the app's state — the
/// selection, whether voice mode is up — and not by which widget mounted
/// last. A surface may [cover] the one that took it, which stands down
/// until the cover goes and is told then, by a notification, to send again.
class ShellAnswer<T extends Object> extends ChangeNotifier {
  ShellAnswer._(this._setUp);

  final void Function(T?) _setUp;
  T? _base;
  final _covers = <T>[];

  /// The one answering, and drawn.
  T? get owner => _covers.lastOrNull ?? _base;

  void _answer(T? was) {
    final now = owner;
    if (identical(was, now)) return;
    _setUp(now);
    notifyListeners();
  }

  /// Takes the surface beneath any cover. Answers whether [surface] is the
  /// one drawn, and so whether what it sends is shown.
  bool take(T surface) {
    final was = owner;
    _base = surface;
    _answer(was);
    return identical(owner, surface);
  }

  /// Answers over whatever took the surface, until [release]d.
  void cover(T surface) {
    final was = owner;
    _covers
      ..remove(surface)
      ..add(surface);
    _answer(was);
  }

  /// Let go, where [surface] was answering or covering. Answers whether it
  /// was the one drawn, and so has what the shell draws for it to take back.
  bool release(T surface) {
    final was = owner;
    if (identical(_base, surface)) {
      _base = null;
    } else if (!_covers.remove(surface)) {
      return false;
    }
    _answer(was);
    return identical(was, surface) && owner == null;
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

  ShellAnswer<T> _answer<T extends Object>(void Function(T?) setUp) =>
      ShellAnswer._((surface) {
        if (identical(_live, this)) setUp(surface);
      });
}

final shellAnswersProvider = Provider<ShellAnswers>((ref) => ShellAnswers());
