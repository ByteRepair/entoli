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

  /// Hex of the public key's SHA-256, grouped in fours — what both sides show
  /// to confirm they are talking to the device they paired with.
  String get fingerprint {
    final digest = slow.sha256.convert(publicKey).toString();
    return [
      for (var i = 0; i + 4 <= digest.length; i += 4) digest.substring(i, i + 4),
    ].join(" ").toUpperCase();
  }

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
    final digest = slow.sha256.convert(pub).bytes;
    return SyncIdentity._(
      pair,
      Uint8List.fromList(pub),
      base64Url.encode(digest.sublist(0, 12)).replaceAll("=", ""),
    );
  }
}
