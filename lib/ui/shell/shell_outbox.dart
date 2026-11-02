import "dart:convert";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "snapshots.dart";

/// Where the snapshots go: [deliver] once per change of a concern's map.
class ShellOutbox {
  ShellOutbox(this.send);

  /// Over [shellChannel], to the Swift.
  factory ShellOutbox.channel() = _ChannelOutbox;

  /// A one-off with no snapshot behind it — the microphone's level, taking
  /// the focus — and, by default, every snapshot's map.
  final void Function(String concern, Map<String, Object?> map) send;
  final Map<String, String> _sent = {};

  void post(ShellSnapshot snapshot) {
    final map = snapshot.toMap();
    final encoded = jsonEncode(map);
    if (_sent[snapshot.concern] == encoded) return;
    _sent[snapshot.concern] = encoded;
    deliver(snapshot.concern, map, encoded);
  }

  /// Send a changed snapshot, [encoded] being its [map] as JSON.
  void deliver(String concern, Map<String, Object?> map, String encoded) =>
      send(concern, map);

  /// Take [snapshot] as what the Swift already shows, without sending it:
  /// what it reported itself, which sent back would undo what it is doing.
  void remember(ShellSnapshot snapshot) =>
      _sent[snapshot.concern] = snapshot.encode();

  /// A one-off with nothing to compare against, such as taking the focus.
  void say(String concern) => send(concern, const {});
}

/// The snapshots as the JSON they were compared as, which the Swift decodes
/// as it is rather than turning the codec's dictionary back into JSON first.
class _ChannelOutbox extends ShellOutbox {
  _ChannelOutbox()
    : super(
        (concern, map) => shellChannel.invokeMethod<void>("snapshot", {
          "concern": concern,
          "value": map,
        }),
      );

  @override
  void deliver(String concern, Map<String, Object?> map, String encoded) =>
      shellChannel.invokeMethod<void>("snapshot", {
        "concern": concern,
        "json": encoded,
      });
}

final shellOutboxProvider = Provider<ShellOutbox>(
  (ref) => ShellOutbox.channel(),
);
