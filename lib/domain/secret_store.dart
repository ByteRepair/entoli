import "dart:typed_data";

/// The keys this app stores. Each becomes one item in the system's keyring
/// where there is one, so a user browsing their secrets sees two Entoli
/// entries however many devices are paired.
const identitySecretKey = "identity";
const pairingSecretsKey = "pairing-secrets";

/// Where this device's sync secrets live: the identity key and the pairing
/// secrets shared with each paired device.
///
/// A system keyring on Linux — the Secret Service API seahorse reads, items
/// labelled "Entoli" — Android's Keystore-backed storage where that is wired
/// in, and a plain file under the data directory where there is neither.
/// [encrypted] says which of those a build got; the Sync page warns on it and
/// nothing else here cares, because every caller wants the same three verbs.
abstract interface class SecretStore {
  /// Null where nothing has been stored under [key] yet.
  Future<Uint8List?> read(String key);

  Future<void> write(String key, Uint8List value);

  Future<void> delete(String key);

  /// Whether secrets are held by the OS rather than in a file this backup
  /// could carry. False means the fallback file is behind every read.
  bool get encrypted;
}
