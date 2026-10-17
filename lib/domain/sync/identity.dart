import "dart:convert";
import "dart:typed_data";

import "package:cryptography/cryptography.dart";
import "package:crypto/crypto.dart" as slow;

import "../secret_store.dart";

/// This device's sync identity: an Ed25519 keypair generated on first use,
/// held by the [SecretStore].
///
/// The id is derived from the public key rather than minted separately, so a
/// device is its key: a registry entry naming one can only be honoured by
/// whoever holds the other half.
class SyncIdentity {
  SyncIdentity._(this.keyPair, this.publicKey, this.id);

  static const protocolVersion = 1;

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  /// Stable across reconnects of the same keys; changes when the identity does.
  final String id;

  /// The SHA-256 of [publicKey] as uppercase hex, ungrouped. What
  /// [fingerprintOf] groups, and what a nameless machine's device name
  /// slices: the announced name rests on this shape rather than on the
  /// fingerprint's presentation, where regrouping would land a space in it.
  static String digestOf(List<int> publicKey) =>
      slow.sha256.convert(publicKey).toString().toUpperCase();

  /// [digestOf], grouped in fours — the shape both screens show.
  static String fingerprintOf(List<int> publicKey) {
    final digest = digestOf(publicKey);
    return [
      for (var i = 0; i + 4 <= digest.length; i += 4) digest.substring(i, i + 4),
    ].join(" ");
  }

  /// Hex of the public key's SHA-256, grouped in fours — a stable name for
  /// this device's key. Shown on a paired device's page, where it can be
  /// compared with what the other device shows under "This device"; nowhere
  /// else reaches a user with it.
  String get fingerprint => fingerprintOf(publicKey);

  /// This device's own [digestOf] — the name's fallback slice reads it.
  String get digest => digestOf(publicKey);

  String get publicKeyB64 => base64Encode(publicKey);

  /// Loads the stored identity, or creates one.
  static Future<SyncIdentity> load(SecretStore store) async {
    final seed = await store.read(identitySecretKey);
    if (seed == null || seed.isEmpty) {
      final pair = await Ed25519().newKeyPair();
      final bytes = await pair.extractPrivateKeyBytes();
      await store.write(identitySecretKey, Uint8List.fromList(bytes));
      return _fromSeed(bytes);
    }
    return _fromSeed(seed);
  }

  static Future<SyncIdentity> _fromSeed(List<int> seed) async {
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final pub = (await pair.extractPublicKey()).bytes;
    return SyncIdentity._(pair, Uint8List.fromList(pub), idOf(pub));
  }

  /// The device id [publicKey] stands for.
  static String idOf(List<int> publicKey) =>
      base64Url.encode(slow.sha256.convert(publicKey).bytes.sublist(0, 12));
}
