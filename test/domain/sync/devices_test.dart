import "package:agent_chat/domain/sync/devices.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final base = {
    "id": "abc",
    "name": "Laptop",
    "publicKey": "",
    "addedAt": "2026-01-01T00:00:00.000",
  };

  test("a record from before the list reads its one address as the list", () {
    final device = PairedDevice.fromJson({
      ...base,
      "lastAddress": "192.168.1.5:47921",
    });
    expect(device.addresses, ["192.168.1.5:47921"]);
  });

  test("the list survives a round trip", () {
    final addresses = ["192.168.1.5:47921", "100.101.102.103:47921"];
    final device = PairedDevice.fromJson({...base, "addresses": addresses});
    expect(PairedDevice.fromJson(device.toJson()).addresses, addresses);
    expect(PairedDevice.fromJson(base).addresses, isEmpty);
  });
}
