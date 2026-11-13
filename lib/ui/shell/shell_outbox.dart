import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";

/// Where the snapshots go: each concern to the [NativeShell], once per
/// change. Most are rebuilt on every frame a turn streams, so a snapshot
/// equal to the last one sent for its concern is not sent again; the
/// contract's classes are values, compared field by field.
class ShellOutbox {
  ShellOutbox([NativeShell? shell]) : _shell = shell ?? NativeShell();

  final NativeShell _shell;
  final Map<String, Object> _sent = {};

  void window(WindowSnapshot snapshot) =>
      _post("window", snapshot, _shell.window);
  void sidebar(SidebarSnapshot snapshot) =>
      _post("sidebar", snapshot, _shell.sidebar);
  void chatBar(ChatBarSnapshot snapshot) =>
      _post("chatBar", snapshot, _shell.chatBar);
  void composer(ComposerSnapshot snapshot) =>
      _post("composer", snapshot, _shell.composer);
  void composerValue(ComposerValueSnapshot snapshot) =>
      _post("composerValue", snapshot, _shell.composerValue);
  void turn(TurnSnapshot snapshot) => _post("turn", snapshot, _shell.turn);
  void newChat(NewChatSnapshot snapshot) =>
      _post("newChat", snapshot, _shell.newChat);
  void voice(VoiceSnapshot snapshot) => _post("voice", snapshot, _shell.voice);
  void palette(PaletteSnapshot snapshot) =>
      _post("palette", snapshot, _shell.palette);
  void foot(ChatFootSnapshot snapshot) => _post("foot", snapshot, _shell.foot);
  void browser(BrowserViewSnapshot snapshot) =>
      _post("browser", snapshot, _shell.browser);

  /// A frame of the browser's page: many a second, each new.
  void browserFrame(BrowserFrameSnapshot frame) =>
      _watch("browserFrame", _shell.browserFrame(frame));

  /// The microphone's level: many times a second, nothing to compare against.
  void voiceLevel(double level) =>
      _watch("voiceLevel", _shell.voiceLevel(level));

  /// A line said to the user in passing: nothing to compare against, each one
  /// said.
  void notice(String message) => _watch("notice", _shell.notice(message));

  /// Give the composer's field the keyboard, or take it away.
  void composerFocus(bool focused) =>
      _watch("composerFocus", _shell.composerFocus(focused));

  void _post<T extends Object>(
    String concern,
    T snapshot,
    Future<void> Function(T) send,
  ) {
    if (_sent[concern] == snapshot) return;
    _sent[concern] = snapshot;
    _watch(concern, send(snapshot));
  }

  static void _watch(String concern, Future<void> sending) => sending
      .catchError((Object e) => logFailure("shell", "snapshot $concern", e));
}

final shellOutboxProvider = Provider<ShellOutbox>((ref) => ShellOutbox());
