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
}

final shellOutboxProvider = Provider<ShellOutbox>(
  (ref) => ShellOutbox.channel(),
);
