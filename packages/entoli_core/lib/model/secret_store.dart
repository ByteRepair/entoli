import "dart:convert";
import "dart:typed_data";

/// The keys this app stores. Each becomes one item in the system's keyring
/// where there is one, so a user browsing their secrets sees a handful of
/// Entoli entries however many providers, devices or models there are. The
/// labels follow the app's name — "Entoli (Debug)" in a debug build — and the
/// lookups carry a `build` attribute, so a debug install's items are its own.
const identitySecretKey = "identity";
const pairingSecretsKey = "pairing-secrets";

/// Map of provider id → API key, for the endpoints configured under
/// `llmProviders`.
const providerKeysKey = "provider-keys";

/// The TURN relay's credential, held beside the username that names it in
/// `settings.json` — the username is not a secret.
const turnPasswordKey = "turn-password";

/// A JSON map under one secret item, the shape the pairing secrets and the
/// provider keys both ride: decode of what [secretBytesOf] wrote.
Map<String, String> secretMapOf(List<int> raw) =>
    (jsonDecode(utf8.decode(raw)) as Map).cast<String, String>();

/// The write twin of [secretMapOf].
Uint8List secretBytesOf(Map<String, String> map) =>
    Uint8List.fromList(utf8.encode(jsonEncode(map)));

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
