import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:cryptography/cryptography.dart";
import "package:cryptography/dart.dart";

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

  /// [reader] is the channel's one reader, and it outlives this: the peer
  /// sends its first framed message the instant the handshake completes, so a
  /// reader cancelled here and replaced afterwards drops whatever landed in
  /// between. Whoever opened it closes it.
  Future<SessionKeys> run(
    ByteChannel raw, {
    required bool initiator,
    required ChannelReader reader,
  }) async {
    final eph = await X25519().newKeyPair();
    final ephPub = Uint8List.fromList((await eph.extractPublicKey()).bytes);
    final hello = {
      "v": SyncIdentity.protocolVersion,
      "role": initiator ? "i" : "j",
      "id": _local.id,
      "pk": _local.publicKeyB64,
      "eph": base64Encode(ephPub),
      "name": name,
    };
    Future<Map<String, dynamic>> receive({bool hello = true}) async {
      final line = utf8.decode(
        await reader.next().timeout(timeout, onTimeout: _timedOut),
      );
      try {
        return parse(line, hello: hello);
      } on ProtocolMismatchException {
        // Said back before giving up, so the other side reads a mismatch
        // too rather than waiting out its timeout. It may be gone already.
        try {
          await raw.send(
            utf8.encode(
              jsonEncode({
                "v": SyncIdentity.protocolVersion,
                "role": initiator ? "i" : "j",
              }),
            ),
          );
        } catch (_) {}
        rethrow;
      }
    }

    if (initiator) await raw.send(utf8.encode(jsonEncode(hello)));
    final remote = await receive();
    if (remote["role"] != (initiator ? "j" : "i")) {
      throw const HandshakeException("unexpected handshake role");
    }
    final remotePk = base64Decode(remote["pk"] as String);
    final remoteEph = base64Decode(remote["eph"] as String);
    // The id is what the registry pins and a reconnect is held to, so it must
    // be the one the signing key stands for, not whatever the peer claims.
    if (remote["id"] != SyncIdentity.idOf(remotePk)) {
      throw const HandshakeException("peer id does not match its key");
    }
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

    Signature signatureOf(List<int> bytes) => Signature(
      bytes,
      publicKey: SimplePublicKey(remotePk, type: KeyPairType.ed25519),
    );

    Future<bool> verify(Object? sig) => Ed25519().verify(
      transcript(),
      signature: signatureOf(base64Decode(sig as String)),
    );

    Future<List<int>> sign() async =>
        (await Ed25519().sign(transcript(), keyPair: _local.keyPair)).bytes;

    SessionKeys keys;
    if (initiator) {
      if (!await verify(remote["sig"])) {
        throw const HandshakeException("joiner signature invalid");
      }
      await raw.send(
        utf8.encode(
          jsonEncode({
            "v": SyncIdentity.protocolVersion,
            "role": "i",
            "sig": base64Encode(await sign()),
          }),
        ),
      );
      keys = await _keys(initiator: true, eph: eph, remoteEph: remoteEph);
    } else {
      await raw.send(
        utf8.encode(jsonEncode({...hello, "sig": base64Encode(await sign())})),
      );
      final last = await receive(hello: false);
      if (last["role"] != "i" || !await verify(last["sig"])) {
        throw const HandshakeException("initiator signature invalid");
      }
      keys = await _keys(initiator: false, eph: eph, remoteEph: remoteEph);
    }
    return keys;
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

  Future<SessionKeys> _keys({
    required bool initiator,
    required SimpleKeyPair eph,
    required List<int> remoteEph,
  }) async {
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
    final ikm = Uint8List.fromList([
      ...dh,
      ...base64Url.decode(base64Url.normalize(pairingSecret)),
    ]);

    // `Hmac` on Android is `javax.crypto`, which refuses the empty-salt key
    // HKDF's extract step builds ("Empty key"); `DartHmac` keeps it in Dart.
    Future<SecretKey> derive(String suffix) => Hkdf(
      hmac: DartHmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: SecretKey(ikm), info: utf8.encode("$info/$suffix"));

    final sasSeed = await Hkdf(
      hmac: DartHmac.sha256(),
      outputLength: 5,
    ).deriveKey(secretKey: SecretKey(ikm), info: utf8.encode(_sasInfo));
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
  ///
  /// The version is read first, so a build whose messages have a different
  /// shape is told it is a mismatch rather than what field it lacks.
  static Map<String, dynamic> parse(String line, {bool hello = true}) {
    final json = jsonDecode(line) as Map<String, dynamic>;
    if (json.containsKey("v") && json["v"] != SyncIdentity.protocolVersion) {
      throw ProtocolMismatchException(json["v"]);
    }
    for (final field in [
      "v",
      "role",
      if (hello) ...["id", "pk", "eph"],
    ]) {
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
  static String formatSas(List<int> bytes) {
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    final bits = bytes.take(5).fold(0, (held, b) => (held << 8) | b);
    final text = [
      for (var shift = 35; shift >= 0; shift -= 5)
        alphabet[(bits >> shift) & 31],
    ].join();
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

/// The two devices speak different versions of [SyncIdentity.protocolVersion]:
/// neither connects until both run a build that agrees. The message is what
/// the pairing page and the device's row show.
class ProtocolMismatchException extends HandshakeException {
  ProtocolMismatchException(Object? theirs)
    : super(
        "Protocol version mismatch, please update Entoli on both devices "
        "(this one speaks ${SyncIdentity.protocolVersion}, the other $theirs).",
      );
}
