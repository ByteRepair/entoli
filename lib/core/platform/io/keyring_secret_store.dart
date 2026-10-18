import "dart:typed_data";

import "package:freedesktop_secret/freedesktop_secret.dart";
import "package:flutter/foundation.dart" show kDebugMode;

import "../../../core/brand.dart";
import "../../../core/log.dart";
import "../../../domain/secret_store.dart";

const _tag = "secrets";

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
  KeyringSecretStore(this._fallback, {SecretServiceClient Function()? service})
      : _connect = service ?? SecretServiceClient.new;

  static const _schema = "io.byterepair.entoli.sync";
  static const _labels = {
    identitySecretKey: "$appBrand — sync identity",
    pairingSecretsKey: "$appBrand — paired devices",
    providerKeysKey: "$appBrand — provider keys",
    turnPasswordKey: "$appBrand — TURN password",
  };

  final SecretStore _fallback;
  final SecretServiceClient Function() _connect;
  SecretServiceClient? _service;
  var _probed = false;

  /// Set once any operation this session landed in the file instead, so
  /// [encrypted] does not promise a keyring the secrets are not in.
  var _fellThrough = false;

  Future<SecretServiceClient?> _probe() async {
    if (_probed) return _service;
    _probed = true;
    try {
      final service = _connect();
      await service.initialize();
      _service = service;
    } catch (error) {
      _service = null;
      logFailure(_tag, "no Secret Service; secrets go to the file", error);
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
      if (item != null) return Uint8List.fromList(item.secretBytes);
    } on Exception catch (error) {
      _fellThrough = true;
      logFailure(_tag, "keyring read of $key failed; reading the file", error);
      return _fallback.read(key);
    }
    // Not in the keyring: a write made while it was locked went to the file,
    // so the file is asked too, and what it holds moves into the keyring.
    final stored = await _fallback.read(key);
    if (stored != null) await write(key, stored);
    return stored;
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
    } on Exception catch (error) {
      _fellThrough = true;
      logFailure(_tag, "keyring write of $key failed; writing the file", error);
      await _fallback.write(key, value);
    }
  }

  @override
  Future<void> delete(String key) async {
    final service = await _probe();
    if (service == null) return _fallback.delete(key);
    try {
      await service.deleteSecret(attributes: _attributes(key));
    } on Exception catch (error) {
      logFailure(_tag, "keyring delete of $key failed", error);
    }
    await _fallback.delete(key);
  }

  /// False until a probe has found the service: the provider settings read
  /// this after startup's secret reads have run it.
  @override
  bool get encrypted => _service != null && !_fellThrough;
}
