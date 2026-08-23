import "dart:async";
import "dart:convert";
import "dart:io";

import "package:agent_chat/data/sync/signaling/relay_signaler.dart";
import "package:flutter_test/flutter_test.dart";

/// The relay rendezvous over a real WebSocket, against the reference relay
/// this repo ships. Both halves are the shipped code — `tool/` is what a user
/// would run, and a relay that forwarded to the wrong side would be found by
/// nothing else.
///
/// The relay itself is copied here rather than imported: `tool/` is outside
/// `lib/` and so not on the package's import path. If the two drift, this
/// test is checking a relay nobody runs — so the copy is deliberately
/// verbatim, and `tool/sync_relay_server.dart` says so.
void main() {
  late HttpServer server;
  late String url;
  final rooms = <String, Map<String, WebSocket>>{};

  setUp(() async {
    rooms.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = "ws://127.0.0.1:${server.port}";
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      _adopt(await WebSocketTransformer.upgrade(request), rooms);
    }, onError: (_) {});
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

/// Verbatim from `tool/sync_relay_server.dart` — see the note at the top.
void _adopt(WebSocket socket, Map<String, Map<String, WebSocket>> rooms) {
  String? room;
  String? role;

  socket.listen(
    (data) {
      if (data is! String) return;
      if (room == null) {
        try {
          final join = jsonDecode(data) as Map<String, dynamic>;
          room = join["join"] as String?;
          role = join["role"] as String?;
        } catch (_) {}
        if (room == null || !{"i", "j"}.contains(role)) {
          socket.close();
          return;
        }
        rooms.putIfAbsent(room!, () => {})[role!] = socket;
        return;
      }
      final peer = rooms[room]?[role == "i" ? "j" : "i"];
      peer?.add(data);
    },
    onError: (_) {},
    onDone: () {
      if (room != null && role != null) {
        final occupants = rooms[room];
        if (occupants?[role] == socket) occupants?.remove(role);
        if (occupants != null && occupants.isEmpty) rooms.remove(room);
      }
    },
  );
}
