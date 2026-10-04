import "dart:typed_data";

import "package:freedesktop_secret/freedesktop_secret.dart";
import "package:flutter/foundation.dart" show kDebugMode;

import "../../../core/brand.dart";
import "../../../domain/secret_store.dart";

/// Secrets in the desktop's keyring — the Secret Service API that seahorse
/// and KWallet's manager read. One item per stored key, labelled so a user
/// browsing their passwords knows where they came from:
///
///   Entoli — sync identity
///   Entoli — paired devices
///   Entoli — provider keys
///   Entoli — TURN password
///
/// (in a debug build, "Entoli (Debug)" throughout). Lookups carry a `build`
/// attribute beside the schema, so a debug install's items are its own and
/// never touch the release one's — the keyring-side twin of the
/// `agent-chat-debug` data directory. Where no service answers — a headless
/// session, a minimal window manager, the dev toolbox — reads and writes
/// fall through to the plain file under the data directory, the same store
/// Android uses. The fallback is decided once, at first use: a session whose
/// daemon appears later is next launch's business.
class KeyringSecretStore implements SecretStore {
  KeyringSecretStore(this._fallback);

  static const _schema = "io.byterepair.entoli.sync";
  static const _labels = {
    identitySecretKey: "$appBrand — sync identity",
    pairingSecretsKey: "$appBrand — paired devices",
    providerKeysKey: "$appBrand — provider keys",
    turnPasswordKey: "$appBrand — TURN password",
  };

  final SecretStore _fallback;
  SecretServiceClient? _service;
  var _probed = false;

  Future<SecretServiceClient?> _probe() async {
    if (_probed) return _service;
    _probed = true;
    try {
      final service = SecretServiceClient();
      await service.initialize();
      _service = service;
    } catch (_) {
      _service = null;
    }
    return _service;
  }

  Map<String, String> _attributes(String key) =>
      {"xdg:schema": _schema, "kind": key, "build": kDebugMode ? "debug" : "release"};

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
        label: _labels[key] ?? "$appBrand — $key",
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
