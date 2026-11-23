/// The relay rendezvous, as the hub uses one: sit in a room, swap SDP with
/// whoever else is in it, hang up.
///
/// An interface rather than the socket itself so a test can open a pairing
/// window without dialling anything — the hub is handed a [RelayDial] and
/// never names the implementation. `RelaySignaler` is what a running app gets.
abstract interface class RelaySignaling {
  /// Everything the other side of the room sends, decoded.
  Stream<Map<String, dynamic>> get messages;

  Future<void> send(Map<String, Object?> json);

  /// Waits for one message carrying [field], or times out.
  Future<Map<String, dynamic>> waitFor(String field, {Duration timeout});

  Future<void> close();
}

/// Join [room] at [relayUrl] as [role] — "i" for the side holding the window,
/// "j" for the side dialling into it.
typedef RelayDial =
    Future<RelaySignaling> Function({
      required String relayUrl,
      required String room,
      required String role,
    });
