import "dart:convert";
import "dart:typed_data";

import "../../core/config.dart";
import "../../domain/documents.dart" show writingSuffix;
import "../../domain/secret_store.dart";
import "../../domain/sync/devices.dart";

/// Paired devices on the disk, their pairing secrets beside them in the
/// [SecretStore].
///
/// The records are public — id, name, public key, when seen — so they live in
/// `<dataDir>/sync/devices.json` where a backup can skip them wholesale. The
/// secrets are not: one JSON map under [pairingSecretsKey], in the keyring
/// wherever there is one.
class FileDeviceRegistry implements DeviceRegistry {
  FileDeviceRegistry(this._config, this._secrets);

  final AppConfig _config;
  final SecretStore _secrets;

  String get _file => _config.fs.path.join(_config.syncDir, "devices.json");

  Future<Map<String, dynamic>> _read() async {
    try {
      final file = _config.fs.file(_file);
      if (!await file.exists()) return {};
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, dynamic> json) async {
    final temp = _config.fs.file("$_file$writingSuffix");
    await temp.writeAsString(jsonEncode(json));
    await temp.rename(_file);
  }

  List<PairedDevice> _devicesOf(Map<String, dynamic> json) => [
        for (final entry
            in (json["devices"] as List<Object?>? ?? const []).cast<Map>())
          PairedDevice.fromJson(entry.cast<String, dynamic>()),
      ];

  @override
  Future<List<PairedDevice>> list() async =>
      _devicesOf(await _read())..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<PairedDevice?> byId(String id) async {
    for (final device in await list()) {
      if (device.id == id) return device;
    }
    return null;
  }

  @override
  Future<void> add(PairedDevice device) async {
    final json = await _read();
    final devices = _devicesOf(json).where((d) => d.id != device.id).toList();
    devices.add(device);
    await _write({"devices": [for (final d in devices) d.toJson()]});
  }

  @override
  Future<void> remove(String id) async {
    final json = await _read();
    final devices = _devicesOf(json).where((d) => d.id != id).toList();
    await _write({"devices": [for (final d in devices) d.toJson()]});
    await setPairingSecret(id, null);
  }

  @override
  Future<void> markSeen(String id, {String? address}) async {
    final device = await byId(id);
    if (device == null) return;
    device.lastSeenAt = DateTime.now();
    if (address != null) device.lastAddress = address;
    await add(device);
  }

  @override
  Future<String?> pairingSecret(String id) async {
    final raw = await _secrets.read(pairingSecretsKey);
    if (raw == null) return null;
    final map = _secretMapOf(raw);
    return map[id];
  }

  @override
  Future<void> setPairingSecret(String id, String? secretB64) async {
    final raw = await _secrets.read(pairingSecretsKey);
    var map = raw == null ? <String, String>{} : _secretMapOf(raw);
    if (secretB64 == null) {
      if (!map.containsKey(id)) return;
      map.remove(id);
    } else {
      map = {...map, id: secretB64};
    }
    await _secrets.write(
        pairingSecretsKey, Uint8List.fromList(utf8.encode(jsonEncode(map))));
  }

  static Map<String, String> _secretMapOf(List<int> raw) =>
      (jsonDecode(utf8.decode(raw)) as Map).cast<String, String>();
}
