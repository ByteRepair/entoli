import "dart:convert";
import "dart:io";

import "package:file/local.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:entoli_core/model/migrations.dart";
import "package:entoli_core/model/sync/devices.dart";

import "../harness.dart";

/// 8.9.0: a paired device's name from before is the user's, all but the
/// "localhost" a phone's hostname gave.
void main() {
  test("a kept name is the user's, localhost is not", () async {
    final dataDir = tempConfig().dataDir;
    Map<String, Object?> device(String id, String name) => {
      "id": id,
      "name": name,
      "publicKey": "",
      "addedAt": DateTime(2026).toIso8601String(),
    };
    final file = File(p.join(dataDir, "sync", "devices.json"))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          "devices": [device("a", "Work"), device("b", "localhost")],
        }),
      );

    await runMigrations(const LocalFileSystem(), dataDir, fresh: false);

    final devices = {
      for (final json
          in (jsonDecode(file.readAsStringSync())["devices"] as List)
              .cast<Map<String, dynamic>>())
        json["id"]: PairedDevice.fromJson(json),
    };
    expect(devices["a"]!.renamed, isTrue);
    expect(devices["a"]!.announcing("thinkpad").name, "Work");
    expect(devices["b"]!.renamed, isFalse);
    expect(devices["b"]!.announcing("iPhone").name, "iPhone");
  });
}
