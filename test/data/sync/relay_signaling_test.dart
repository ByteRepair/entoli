import "dart:async";
import "dart:io";

import "package:agent_chat/data/sync/signaling/relay_signaler.dart";
import "package:flutter_test/flutter_test.dart";

import "../../../tool/sync_relay_server.dart";

/// The relay rendezvous over a real WebSocket. Both halves are the shipped
/// code — `tool/sync_relay_server.dart` is what a user would run, imported
/// here rather than copied, since a second implementation in the test would
/// let the one people actually run drift out from under it. A relay that
/// forwarded to the wrong side would be found by nothing else.
void main() {
  late HttpServer server;
  late String url;

  setUp(() async {
    server = await RelayServer().start(0, address: InternetAddress.loopbackIPv4);
    url = "ws://127.0.0.1:${server.port}";
  });

  tearDown(() => server.close(force: true));

  test("a room token gives nothing away about the secret it came from", () {
    final room = RelaySignaler.roomFor("a-pairing-secret");

    expect(room, isNot(contains("a-pairing-secret")));
    expect(room, RelaySignaler.roomFor("a-pairing-secret"));
    expect(room, isNot(RelaySignaler.roomFor("another-secret")));
    // Base64url of twelve bytes, lowercased and unpadded.
    expect(room, matches(RegExp(r"^[a-z0-9_-]{16}$")));
  });

  test("what one side sends, the other side gets", () async {
    final room = RelaySignaler.roomFor("secret");
    final host = await RelaySignaler.connect(
        relayUrl: url, room: room, role: "i");
    final joiner = await RelaySignaler.connect(
        relayUrl: url, room: room, role: "j");
    addTearDown(host.close);
    addTearDown(joiner.close);

    final waiting = host.waitFor("offer");
    await joiner.send({"offer": "v=0 offer"});
    expect((await waiting)["offer"], "v=0 offer");

    final answered = joiner.waitFor("answer");
    await host.send({"answer": "v=0 answer"});
    expect((await answered)["answer"], "v=0 answer");
  });

  test("a third party in another room hears nothing", () async {
    final ours = await RelaySignaler.connect(
        relayUrl: url, room: RelaySignaler.roomFor("ours"), role: "i");
    final theirs = await RelaySignaler.connect(
        relayUrl: url, room: RelaySignaler.roomFor("theirs"), role: "j");
    addTearDown(ours.close);
    addTearDown(theirs.close);

    final overheard = <Map<String, dynamic>>[];
    theirs.messages.listen(overheard.add);
    final joiner = await RelaySignaler.connect(
        relayUrl: url, room: RelaySignaler.roomFor("ours"), role: "j");
    addTearDown(joiner.close);

    await joiner.send({"offer": "v=0 offer"});
    expect((await ours.waitFor("offer"))["offer"], "v=0 offer");
    expect(overheard, isEmpty);
  });

  test("a message with nothing waiting for it does not stop the next one",
      () async {
    final room = RelaySignaler.roomFor("secret");
    final host = await RelaySignaler.connect(
        relayUrl: url, room: room, role: "i");
    final joiner = await RelaySignaler.connect(
        relayUrl: url, room: room, role: "j");
    addTearDown(host.close);
    addTearDown(joiner.close);

    final waiting = host.waitFor("offer");
    await joiner.send({"noise": 1});
    await joiner.send({"offer": "v=0 offer"});

    expect((await waiting)["offer"], "v=0 offer");
  });

  test("waiting for what never comes times out rather than hanging", () async {
    final room = RelaySignaler.roomFor("secret");
    final host = await RelaySignaler.connect(
        relayUrl: url, room: room, role: "i");
    addTearDown(host.close);

    await expectLater(
      host.waitFor("answer", timeout: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test("a relay that is not there fails to connect rather than waiting",
      () async {
    await server.close(force: true);

    await expectLater(
      RelaySignaler.connect(
          relayUrl: url,
          room: "room",
          role: "i",
          timeout: const Duration(seconds: 2)),
      throwsA(anything),
    );
  });
}
