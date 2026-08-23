import "dart:async";
import "dart:convert";

import "package:crypto/crypto.dart" as slow;
import "package:web_socket_channel/web_socket_channel.dart";

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
  RelaySignaler(this._channel);

  final WebSocketChannel _channel;
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _sub;

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
    final channel = WebSocketChannel.connect(Uri.parse(relayUrl));
    await channel.ready.timeout(timeout);
    final signaler = RelaySignaler(channel);
    signaler._sub = channel.stream.listen(
      (data) {
        try {
          signaler._incoming.add(
              jsonDecode(data as String) as Map<String, dynamic>);
        } catch (_) {}
      },
      onError: signaler._incoming.addError,
      onDone: signaler._incoming.close,
    );
    channel.sink.add(jsonEncode({"join": room, "role": role}));
    return signaler;
  }

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  Future<void> send(Map<String, Object?> json) async =>
      _channel.sink.add(jsonEncode(json));

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
    await _channel.sink.close();
    await _incoming.close();
  }
}
