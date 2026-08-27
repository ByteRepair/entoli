import "dart:typed_data";

import "package:freedesktop_secret/freedesktop_secret.dart";

import "../../../domain/secret_store.dart";

/// Secrets in the desktop's keyring — the Secret Service API that seahorse
/// and KWallet's manager read. Two items, labelled so a user browsing their
/// passwords knows where they came from:
///
///   Entoli — sync identity
///   Entoli — paired devices
///
/// Where no service answers — a headless session, a minimal window manager,
/// the dev toolbox — reads and writes fall through to the plain file under
/// the data directory, the same store Android uses. The fallback is decided
/// once, at first use: a session whose daemon appears later is next launch's
/// business.
class KeyringSecretStore implements SecretStore {
  KeyringSecretStore(this._fallback);

  static const _schema = "io.github.yiannis128.agentchat.sync";
  static const _labels = {
    identitySecretKey: "Entoli — sync identity",
    pairingSecretsKey: "Entoli — paired devices",
  };

  final SecretStore _fallback;
  FreeDesktopSecret? _service;
  var _probed = false;

  Future<FreeDesktopSecret?> _probe() async {
    if (_probed) return _service;
    _probed = true;
    try {
      final service = FreeDesktopSecret();
      await service.initialize();
      _service = service;
    } catch (_) {
      _service = null;
    }
    return _service;
  }

  Map<String, String> _attributes(String key) =>
      {"xdg:schema": _schema, "kind": key};

  @override
  Future<Uint8List?> read(String key) async {
    final service = await _probe();
    if (service == null) return _fallback.read(key);
    try {
      final item = await service.lookupSecret(attributes: _attributes(key));
      if (item == null) return null;
      return Uint8List.fromList(item.secretBytes);
    } on Exception {
      return _fallback.read(key);
    }
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    final service = await _probe();
    if (service == null) return _fallback.write(key, value);
    try {
      await service.storeSecret(
        attributes: _attributes(key),
        secretBytes: value,
        // Bytes, not text: keys are binary, and the content type libsecret's
        // own CLI chokes on is one more thing not to ship.
        contentType: "application/octet-stream",
        label: _labels[key] ?? "Entoli — $key",
        replace: true,
      );
      // The file copy is removed where it exists: a secret that moved into
      // the keyring must not stay readable on disk beside it.
      await _fallback.delete(key);
    } on Exception {
      await _fallback.write(key, value);
    }
  }

  @override
  Future<void> delete(String key) async {
    final service = await _probe();
    if (service == null) return _fallback.delete(key);
    try {
      await service.deleteSecret(attributes: _attributes(key));
    } on Exception {
      // Nothing to do: absent is what delete wants.
    }
    await _fallback.delete(key);
  }

  @override
  bool get encrypted => true;
}
