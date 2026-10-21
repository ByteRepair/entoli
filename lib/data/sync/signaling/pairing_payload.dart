import "dart:convert";
import "dart:math";
import "dart:typed_data";

/// What one device tells another so the two can find each other and open a
/// data channel: where to rendezvous (a LAN signaling server, a relay room,
/// or nothing at all when the SDP rides in the blob itself), the pairing
/// secret that authenticates the channel once it is up, and a name.
///
/// The secret travels only through this object — shown as a QR, typed as a
/// code, pasted as text — never through the rendezvous itself, which is what
/// makes a machine in the middle unable to derive the channel keys. See
/// `handshake.dart`.
class PairingOffer {
  PairingOffer({
    required this.kind,
    required this.psk,
    required this.name,
    this.hosts = const [],
    this.port = 0,
    this.relayUrl = "",
    this.code = "",
    this.sdp = "",
    this.tag = "",
  });

  static const lanKind = "lan";
  static const relayKind = "relay";
  static const offerKind = "manual-offer";
  static const answerKind = "manual-answer";

  final String kind;
  final String psk;
  final String name;

  /// LAN: every address the signaling server answers on, probed at once.
  final List<String> hosts;
  final int port;

  /// Relay mode: the user-supplied WebSocket endpoint. The room is derived
  /// from the secret, so it is not written here either.
  final String relayUrl;

  /// The one-time code the LAN server expects while its window is open.
  final String code;

  /// Manual mode: the SDP itself rides in the blob.
  final String sdp;

  /// Manual mode: which pending invite an answer belongs to. Derived from
  /// the secret, so it says nothing the QR did not already say.
  final String tag;

  Map<String, Object> toJson() => {
        "v": 1,
        "kind": kind,
        "psk": psk,
        "name": name,
        if (kind == lanKind) ...{
          "hosts": hosts,
          "port": port,
          if (code.isNotEmpty) "code": code,
        },
        if (kind == relayKind) "relay": relayUrl,
        if (sdp.isNotEmpty) ...{"sdp": sdp, if (tag.isNotEmpty) "tag": tag},
      };

  factory PairingOffer.fromJson(Map<String, dynamic> json) {
    final kind = json["kind"] as String? ?? "";
    return PairingOffer(
      kind: kind,
      psk: json["psk"] as String? ?? "",
      name: json["name"] as String? ?? "",
      hosts:
          [for (final h in (json["hosts"] as List<Object?>? ?? const [])) h as String],
      port: json["port"] as int? ?? 0,
      relayUrl: json["relay"] as String? ?? "",
      code: json["code"] as String? ?? "",
      sdp: json["sdp"] as String? ?? "",
      tag: json["tag"] as String? ?? "",
    );
  }

  /// What the QR holds and what manual pairing pastes.
  String encode() =>
      "$prefix${base64Url.encode(utf8.encode(jsonEncode(toJson()))).replaceAll("=", "")}";

  static const prefix = "entoli-pair:";

  static PairingOffer? decode(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final normalized = base64Url.normalize(trimmed.substring(prefix.length));
      return PairingOffer.fromJson(
          jsonDecode(utf8.decode(base64Url.decode(normalized))) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

final _random = Random.secure();

/// A fresh pairing secret: 32 random bytes, base64url. High entropy is what
/// lets the handshake lean on it instead of a human-chosen passphrase.
String generatePsk() {
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _random.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll("=", "");
}

/// Six characters from an unambiguous set, grouped — typed into the other
/// device when scanning a QR is not convenient.
String generatePairingCode() {
  const alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
  final chars =
      List.generate(6, (_) => alphabet[_random.nextInt(alphabet.length)]);
  return "${chars.take(3).join()}-${chars.skip(3).join()}";
}
