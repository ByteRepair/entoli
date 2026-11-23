import "channel.dart";

/// A peer connection reduced to what sync needs from it: negotiate SDP
/// through whatever rendezvous brought the two sides together, then hand
/// over one [ByteChannel]. `entoli_sync_transport` is the WebRTC one.
abstract interface class PeerLink {
  /// The initiator's half: owns the channel and returns the offer to send.
  Future<String> offer();

  /// The joiner's half: takes the remote offer and returns the answer.
  Future<String> answer(String remoteSdp);

  /// Completes the initiator once the joiner's answer arrives.
  Future<void> acceptAnswer(String remoteSdp);

  /// The channel once it is open. Throws when the peer goes away instead.
  Future<ByteChannel> open({Duration timeout = const Duration(seconds: 30)});

  Future<void> close();
}

/// Opens a [PeerLink] over [iceServers], STUN and TURN entries in the
/// `{"urls", "username", "credential"}` shape.
typedef PeerLinkFactory =
    Future<PeerLink> Function({required List<Map<String, Object>> iceServers});
