import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "snapshots.dart";

/// Where the snapshots go: [send] once per change of a concern's map.
class ShellOutbox {
  ShellOutbox(this.send);

  /// Over [shellChannel], to the Swift.
  ShellOutbox.channel()
    : send = ((concern, map) => shellChannel.invokeMethod<void>("snapshot", {
        "concern": concern,
        "value": map,
      }));

  final void Function(String concern, Map<String, Object?> map) send;
  final Map<String, String> _sent = {};

  void post(ShellSnapshot snapshot) {
    final encoded = snapshot.encode();
    if (_sent[snapshot.concern] == encoded) return;
    _sent[snapshot.concern] = encoded;
    send(snapshot.concern, snapshot.toMap());
  }

  /// Take [snapshot] as what the Swift already shows, without sending it:
  /// what it reported itself, which sent back would undo what it is doing.
  void remember(ShellSnapshot snapshot) =>
      _sent[snapshot.concern] = snapshot.encode();

  /// A one-off with nothing to compare against, such as taking the focus.
  void say(String concern) => send(concern, const {});
}

final shellOutboxProvider = Provider<ShellOutbox>(
  (ref) => ShellOutbox.channel(),
);
