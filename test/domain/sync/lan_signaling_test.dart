import "package:agent_chat/domain/sync/lan_signaling.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("broadcasts to the limited address and each private /24", () {
    expect(lanBroadcasts(["192.168.1.5", "10.0.0.2", "172.16.4.2"]), [
      "255.255.255.255",
      "192.168.1.255",
      "10.0.0.255",
      "172.16.4.255",
    ]);
  });

  test("leaves out public and tailnet addresses", () {
    expect(lanBroadcasts(["100.101.102.103", "8.8.8.8", "172.32.0.1"]), [
      "255.255.255.255",
    ]);
  });
}
