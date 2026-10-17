import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/documents.dart" show RenameWriter;
import "../../domain/secret_store.dart";

/// Secrets in a plain file under the data directory — what a platform gets
/// where there is no system keyring to hold them: Android before its Keystore
/// wiring lands, a browser (origin-scoped IndexedDB is the ceiling there), and
/// a Linux whose session has no Secret Service.
///
/// The Sync page says when this is behind a device's secrets rather than the
/// keyring; nothing else in the app can tell the difference.
class FileSecretStore implements SecretStore {
  FileSecretStore(AppConfig config)
      : _file = config.fs.file(config.fs.path.join(config.syncDir, "secrets.json")),
        _writer = RenameWriter.fs(config.fs);

  final File _file;
  final RenameWriter _writer;

  /// Loaded once and shared: two first calls racing each other would each
  /// load a map of their own, and the later write would drop the earlier key.
  late final Future<Map<String, String>> _values = _load();

  Future<Map<String, String>> _load() async {
    final values = <String, String>{};
    try {
      if (await _file.exists()) {
        values.addAll((jsonDecode(await _file.readAsString()) as Map).cast<String, String>());
      }
    } catch (e) {
      // Unreadable is unpaired: start over rather than fail the app.
      logFailure("secrets", "secrets.json could not be read; starting empty", e);
    }
    return values;
  }

  Future<void> _write(Map<String, String> values) =>
      _writer.write(_file.path, jsonEncode(values));

  @override
  Future<Uint8List?> read(String key) async {
    final value = (await _values)[key];
    if (value == null) return null;
    try {
      return Uint8List.fromList(base64Decode(value));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    final values = await _values;
    values[key] = base64Encode(value);
    await _write(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _values;
    if (values.remove(key) != null) await _write(values);
  }

  @override
  bool get encrypted => false;
}
