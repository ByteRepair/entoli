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
  void pageBar(TitleBarSnapshot snapshot) =>
      _post("pageBar", snapshot, _shell.pageBar);
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

  /// Take [value] as what the shell's composer already holds, without sending
  /// it: what it reported itself, which sent back would undo what it is
  /// doing.
  void rememberComposerValue(ComposerValueSnapshot value) =>
      _sent["composerValue"] = value;

  /// The microphone's level: many times a second, nothing to compare against.
  void voiceLevel(double level) =>
      _watch("voiceLevel", _shell.voiceLevel(level));

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
