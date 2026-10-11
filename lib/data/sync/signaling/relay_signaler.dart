import "dart:async";
import "dart:convert";

import "package:crypto/crypto.dart" as slow;

import "../../../core/tls.dart";

import "../../../domain/sync/relay_signaling.dart";

/// The joiner-or-host half of a relay pairing. Both sides dial the same
/// user-supplied WebSocket endpoint and join the same room — derived from the
/// pairing secret, so the relay learns nothing it could not already be told —
/// and everything either sends is forwarded to the other.
///
/// The relay sees only this framing and opaque SDP payloads; nothing readable
/// crosses it, because the channel keys come from the handshake that runs
/// after the data channel is up, not from anything here.
class RelaySignaler implements RelaySignaling {
  /// The socket as two halves rather than a `WebSocketChannel`, because
  /// nothing below needs one — and a pair of controllers is then a whole
  /// relay a test can hold both ends of without dialling anything.
  ///
  /// Joins on construction: there is no useful state before that.
  RelaySignaler({
    required Stream<Object?> incoming,
    required this.outgoing,
    required String room,
    required String role,
  }) {
    _sub = incoming.listen(
      (data) {
        try {
          _decoded.add(jsonDecode(data as String) as Map<String, dynamic>);
        } catch (_) {}
      },
      onError: _decoded.addError,
      onDone: _decoded.close,
    );
    outgoing.add(jsonEncode({"join": room, "role": role}));
  }

  final StreamSink<Object?> outgoing;
  final _decoded = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<Object?>? _sub;

  /// The room token for a pairing secret: 12 bytes of its SHA-256. Both ends
  /// compute the same value from the same secret; nobody without it finds the
  /// room to shout into.
  static String roomFor(String psk) {
    final digest = slow.sha256.convert(utf8.encode(psk)).bytes;
    return base64Url
        .encode(digest.sublist(0, 12))
        .replaceAll("=", "")
        .toLowerCase();
  }

  /// Joins [room] as [role] ("i" or "j") and starts relaying.
  static Future<RelaySignaler> connect({
    required String relayUrl,
    required String room,
    required String role,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final channel = await tlsWebSocketChannel(Uri.parse(relayUrl), readyTimeout: timeout);
    return RelaySignaler(
        incoming: channel.stream,
        outgoing: channel.sink,
        room: room,
        role: role);
  }

  @override
  Stream<Map<String, dynamic>> get messages => _decoded.stream;

  @override
  Future<void> send(Map<String, Object?> json) async =>
      outgoing.add(jsonEncode(json));

  @override
  Future<Map<String, dynamic>> waitFor(String field,
      {Duration timeout = const Duration(seconds: 45)}) async {
    return messages
        .firstWhere((m) => m.containsKey(field))
        .timeout(timeout);
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await outgoing.close();
    await _decoded.close();
  }
}
