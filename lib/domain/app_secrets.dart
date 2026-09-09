import "dart:convert";
import "dart:typed_data";

import "secret_store.dart";

/// The secrets that are not sync's: every provider's API key and the TURN
/// relay's password, held beside the two sync items in the same store.
///
/// The keys cross as a single map under one item — [secretMapOf] is the codec
/// the pairing secrets share — because one item per key would make a user
/// browsing their keyring count providers instead of seeing the app. A map
/// that writes to empty deletes the item, so a device with no providers
/// stores nothing at all.
///
/// Reads are served from the in-memory mirror and are synchronous, because
/// `LlmRegistry` resolves a key on the path to every model call; the mirror is
/// filled once at startup by [load].
class AppSecrets {
  AppSecrets(this._store);

  final SecretStore _store;

  Map<String, String> _providers = const {};
  String? _turnPassword;

  Future<void> load() async {
    final (keys, turn) =
        await (_store.read(providerKeysKey), _store.read(turnPasswordKey)).wait;
    _providers = keys == null || keys.isEmpty ? const {} : secretMapOf(keys);
    _turnPassword = turn == null || turn.isEmpty ? null : utf8.decode(turn);
  }

  /// The stored key for a provider, or null for none. Sync: read off the
  /// mirror, so a model call is never held on a keyring round trip.
  String? providerKey(String providerId) => _providers[providerId];

  /// Whether the store behind this is the OS keyring — what the settings page
  /// says where it names where a key went.
  bool get encrypted => _store.encrypted;

  /// Stores or clears one provider's key. Null removes the entry; a key that
  /// is already the stored value writes nothing, so toggling a dialog open and
  /// shut saves nothing.
  Future<void> setProviderKey(String providerId, String? key) async {
    if (key == null || key.isEmpty) {
      if (!_providers.containsKey(providerId)) return;
      _providers = {
        for (final entry in _providers.entries)
          if (entry.key != providerId) entry.key: entry.value,
      };
    } else {
      if (_providers[providerId] == key) return;
      _providers = {..._providers, providerId: key};
    }
    await _writeProviders();
  }

  Future<void> _writeProviders() async {
    if (_providers.isEmpty) {
      await _store.delete(providerKeysKey);
      return;
    }
    await _store.write(providerKeysKey, secretBytesOf(_providers));
  }

  /// The TURN credential, or null for none. Sync, like the provider keys.
  String? get turnPassword => _turnPassword;

  Future<void> setTurnPassword(String? password) async {
    if (password == null || password.isEmpty) {
      if (_turnPassword == null) return;
      _turnPassword = null;
      await _store.delete(turnPasswordKey);
      return;
    }
    if (_turnPassword == password) return;
    _turnPassword = password;
    await _store.write(
        turnPasswordKey, Uint8List.fromList(utf8.encode(password)));
  }
}
