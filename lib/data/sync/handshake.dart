import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:cryptography/cryptography.dart";

import "../../domain/sync/identity.dart";
import "channel.dart";

/// The authenticated key exchange two devices run over a fresh [ByteChannel]
/// before any application message moves.
///
/// Three plaintext messages:
///
///   initiator -> joiner  {"v","role":"i","id","pk","eph","name"}
///   joiner -> initiator  {"v","role":"j", ...same..., "sig"}
///   initiator -> joiner  {"v","role":"i","sig"}
///
/// Both sides sign the transcript — both identity keys and both ephemeral
/// keys, in a fixed role order — with their Ed25519 identity key. A
/// reconnect is therefore held to the public key pinned in the registry
/// ([requirePeerId]); a first pairing is held to whoever had the pairing
/// secret out of band.
///
/// The channel keys are HKDF-SHA256 over the X25519 shared secret and the
/// pairing secret. The pairing secret never crossed the network — it came in
/// the QR or the typed code — so a machine in the middle that substitutes its
/// own ephemeral keys derives different keys than either victim, and its
/// first framed message fails to authenticate. The SAS derived beside the
/// keys lets two humans confirm it by eye as well.
class Handshake {
  Handshake(this._local, {required this.pairingSecret, this.name = ""});

  static const info = "entoli-channel-v1";
  static const _sigContext = "entoli-handshake-v1";
  static const _sasInfo = "entoli-sas";

  /// How long to wait for any one handshake message.
  static const timeout = Duration(seconds: 15);

  final SyncIdentity _local;
  final String pairingSecret;

  /// This device's name, as the other side's registry will hold it.
  final String name;

  PeerIdentity? _peer;

  /// Who we shook hands with. Null until [run] succeeds.
  PeerIdentity? get peer => _peer;

  String? _sasText;

  /// What both screens show after a successful exchange, for comparing by eye.
  String? get sas => _sasText;

  Future<SessionKeys> run(ByteChannel raw,
      {required bool initiator}) async {
    final reader = ChannelReader(raw);
    try {
      final eph = await X25519().newKeyPair();
      final ephPub =
          Uint8List.fromList((await eph.extractPublicKey()).bytes);

      Map<String, dynamic> remote;
      if (initiator) {
        await raw.send(utf8.encode(jsonEncode(_hello("i", ephPub))));
        remote = parse(utf8.decode(
            await reader.next().timeout(timeout, onTimeout: _timedOut)));
        if (remote["role"] != "j") {
          throw const HandshakeException("unexpected handshake role");
        }
      } else {
        remote = parse(utf8.decode(
            await reader.next().timeout(timeout, onTimeout: _timedOut)));
        if (remote["role"] != "i") {
          throw const HandshakeException("unexpected handshake role");
        }
      }
      if (remote["v"] != SyncIdentity.protocolVersion) {
        throw HandshakeException(
            "protocol version ${remote["v"]} not supported");
      }

      final remotePk = base64Decode(remote["pk"] as String);
      final remoteEph = base64Decode(remote["eph"] as String);
      _peer = PeerIdentity(
        id: remote["id"] as String,
        publicKey: Uint8List.fromList(remotePk),
        name: (remote["name"] as String?) ?? "",
      );

      // Fixed order by role, so both sides hash the same bytes — local
      // first would have each side signing its own ordering.
      List<int> transcript() => [
            ...utf8.encode(_sigContext),
            ...(initiator ? ephPub : remoteEph),
            ...(initiator ? remoteEph : ephPub),
            ...(initiator ? _local.publicKey : remotePk),
            ...(initiator ? remotePk : _local.publicKey),
          ];

      Signature signatureOf(List<int> bytes) => Signature(bytes,
          publicKey: SimplePublicKey(remotePk, type: KeyPairType.ed25519));

      Future<bool> verify(Object? sig) =>
          Ed25519().verify(transcript(), signature: signatureOf(base64Decode(sig as String)));

      Future<List<int>> sign() async =>
          (await Ed25519().sign(transcript(), keyPair: _local.keyPair)).bytes;

      SessionKeys keys;
      if (initiator) {
        if (!await verify(remote["sig"])) {
          throw const HandshakeException("joiner signature invalid");
        }
        await raw.send(utf8.encode(jsonEncode({
          "v": SyncIdentity.protocolVersion,
          "role": "i",
          "sig": base64Encode(await sign()),
        })));
        keys = await _keys(initiator: true, eph: eph, remoteEph: remoteEph);
      } else {
        await raw.send(utf8.encode(jsonEncode({
          "v": SyncIdentity.protocolVersion,
          "role": "j",
          "id": _local.id,
          "pk": _local.publicKeyB64,
          "eph": base64Encode(ephPub),
          "name": name,
          "sig": base64Encode(await sign()),
        })));
        final last = parse(
            utf8.decode(
                await reader.next().timeout(timeout, onTimeout: _timedOut)),
            hello: false);
        if (last["role"] != "i" || !await verify(last["sig"])) {
          throw const HandshakeException("initiator signature invalid");
        }
        keys = await _keys(initiator: false, eph: eph, remoteEph: remoteEph);
      }
      return keys;
    } finally {
      await reader.cancel();
    }
  }

  /// Holds the peer to the id recorded when they were paired. Their id
  /// travels inside signed material, so failing here means their key changed
  /// since pairing — refuse rather than re-pair silently.
  void requirePeerId(String expected) {
    final peer = _peer;
    if (peer == null || peer.id != expected) {
      throw const HandshakeException("peer is not who we paired with");
    }
  }

  Map<String, Object> _hello(String role, Uint8List ephPub) => {
        "v": SyncIdentity.protocolVersion,
        "role": role,
        "id": _local.id,
        "pk": _local.publicKeyB64,
        "eph": base64Encode(ephPub),
        "name": name,
      };

  Future<SessionKeys> _keys(
      {required bool initiator,
      required SimpleKeyPair eph,
      required List<int> remoteEph}) async {
    final shared = await X25519().sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(remoteEph, type: KeyPairType.x25519),
    );
    final dh = await shared.extractBytes();
    // Normalised before decoding: `generatePsk` strips the padding so the
    // secret fits in a QR without an `=` in it, and a bare `base64Decode`
    // refuses a length that is not a multiple of four — which every real
    // secret is, being 32 bytes. `normalize` also accepts either alphabet, so
    // a secret that came through a QR and one typed by hand agree.
    final ikm = Uint8List.fromList(
        [...dh, ...base64Url.decode(base64Url.normalize(pairingSecret))]);

    Future<SecretKey> derive(String suffix) => Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: SecretKey(ikm), info: utf8.encode("$info/$suffix"));

    final sasSeed = await Hkdf(hmac: Hmac.sha256(), outputLength: 5)
        .deriveKey(secretKey: SecretKey(ikm), info: utf8.encode(_sasInfo));
    _sasText = formatSas(await sasSeed.extractBytes());

    // Labels are fixed to roles, not sides: a2b is always the initiator's
    // sending key, whichever end of the wire this is.
    return SessionKeys(
      send: await derive(initiator ? "a2b" : "b2a"),
      recv: await derive(initiator ? "b2a" : "a2b"),
    );
  }

  /// [hello] is the two opening messages, which carry an identity; the
  /// initiator's closing one is a signature and nothing else.
  static Map<String, dynamic> parse(String line, {bool hello = true}) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    for (final field in ["v", "role", if (hello) ...["id", "pk", "eph"]]) {
      if (!json.containsKey(field)) {
        throw HandshakeException("handshake message missing $field");
      }
    }
    return json;
  }

  static Never _timedOut() => throw const HandshakeException("timed out");

  /// Eight characters of base32 without lookalikes, grouped 4+4 — the forty
  /// bits the derivation gives, which an attacker gets no offline oracle for
  /// and one online guess per connection attempt.
  ///
  /// Regrouped five bits at a time rather than through one 40-bit integer:
  /// a shift past 32 bits is truncated on the web.
  static String formatSas(List<int> bytes) {
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    final chars = StringBuffer();
    var held = 0, bits = 0;
    for (final b in bytes.take(5)) {
      held = ((held << 8) | b) & 0xfff;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        chars.write(alphabet[(held >> bits) & 31]);
      }
    }
    final text = chars.toString();
    return "${text.substring(0, 4)}-${text.substring(4)}";
  }
}

/// Who we just shook hands with, before they are in the registry.
class PeerIdentity {
  PeerIdentity({required this.id, required this.publicKey, required this.name});

  final String id;
  final Uint8List publicKey;
  final String name;

  String get publicKeyB64 => base64Encode(publicKey);
}

/// The directional keys a completed handshake produced.
class SessionKeys {
  SessionKeys({required this.send, required this.recv});

  final SecretKey send;
  final SecretKey recv;
}

class HandshakeException implements Exception {
  const HandshakeException(this.message);
  final String message;

  @override
  String toString() => message;
}
