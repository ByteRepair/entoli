import "dart:async";
import "dart:convert";

import "package:agent_chat/data/sync/signaling/relay_signaler.dart";
import "package:flutter_test/flutter_test.dart";

import "../../../tool/sync/sync_relay_server.dart";

/// The relay, both halves, with no socket between them. `RelayRooms` is the
/// shipped forwarding — `tool/sync/sync_relay_server.dart` is what a user would
/// run, imported here rather than copied, since a second implementation in the
/// test would let the one people actually run drift out from under it. A relay
/// that forwarded to the wrong side would be found by nothing else.
void main() {
  test("a room token gives nothing away about the secret it came from", () {
    final room = RelaySignaler.roomFor("a-pairing-secret");

    expect(room, isNot(contains("a-pairing-secret")));
    expect(room, RelaySignaler.roomFor("a-pairing-secret"));
    expect(room, isNot(RelaySignaler.roomFor("another-secret")));
    // Base64url of twelve bytes, lowercased and unpadded.
    expect(room, matches(RegExp(r"^[a-z0-9_-]{16}$")));
  });

  group("the rooms", () {
    late RelayRooms rooms;

    setUp(() => rooms = RelayRooms());

    _FakePeer join(String room, String role) {
      final peer = _FakePeer();
      rooms.adopt(peer);
      peer.say(jsonEncode({"join": room, "role": role}));
      return peer;
    }

    test("what one side sends, the other side gets", () async {
      final host = join("room", "i");
      final joiner = join("room", "j");

      joiner.say("offer");
      host.say("answer");
      await pumpEventQueue();

      expect(host.sent, ["offer"]);
      expect(joiner.sent, ["answer"]);
    });

    test("a third party in another room hears nothing", () async {
      final ours = join("ours", "i");
      final theirs = join("theirs", "i");
      final joiner = join("ours", "j");

      joiner.say("offer");
      await pumpEventQueue();

      expect(ours.sent, ["offer"]);
      expect(theirs.sent, isEmpty);
    });

    test("a reconnecting role takes the slot over, and its predecessor's "
        "leave changes nothing", () async {
      final host = join("room", "i");
      final joiner = join("room", "j");
      final again = join("room", "j");

      host.say("answer");
      await pumpEventQueue();

      expect(again.sent, ["answer"]);
      expect(joiner.sent, isEmpty);

      // Rejoining and then dropping the old socket is the ordinary shape of
      // a reconnect, and taking the room down with it would strand the new
      // one.
      await joiner.leave();
      host.say("answer again");
      await pumpEventQueue();

      expect(again.sent, ["answer", "answer again"]);
    });

    test("a side that has left is not still forwarded to", () async {
      final host = join("room", "i");
      final joiner = join("room", "j");
      await joiner.leave();

      host.say("answer");
      await pumpEventQueue();

      expect(joiner.sent, isEmpty);
    });

    test(
      "an invalid first message — non-join or bad role — closes the peer",
      () async {
        final peer = _FakePeer();
        rooms.adopt(peer);

        peer.say("not json at all");
        await pumpEventQueue();
        expect(peer.closed, isTrue);

        final second = _FakePeer();
        rooms.adopt(second);
        second.say(jsonEncode({"join": "room", "role": "eavesdropper"}));
        await pumpEventQueue();
        expect(second.closed, isTrue);
      },
    );
  });

  group("the signaler", () {
    late StreamController<Object?> incoming;
    late RelaySignaler signaler;

    /// What went out to the relay, the join included.
    late List<Object?> sent;

    setUp(() {
      incoming = StreamController<Object?>();
      final outgoing = StreamController<Object?>();
      sent = [];
      outgoing.stream.listen(sent.add);
      signaler = RelaySignaler(
        incoming: incoming.stream,
        outgoing: outgoing.sink,
        room: "room",
        role: "i",
      );
    });

    tearDown(() async {
      await signaler.close();
      await incoming.close();
    });

    test("the join is first, and the send is echoed whole", () async {
      await signaler.send({"offer": "v=0 offer"});
      await pumpEventQueue();

      // The room join is what announces the role.
      expect(sent.first, jsonEncode({"join": "room", "role": "i"}));
      // And what was sent is what the other side is given.
      expect(jsonDecode(sent.last! as String), {"offer": "v=0 offer"});
    });

    test(
      "a message with nothing waiting for it does not stop the next one",
      () async {
        final waiting = signaler.waitFor("offer");

        incoming.add(jsonEncode({"noise": 1}));
        incoming.add(jsonEncode({"offer": "v=0 offer"}));

        expect((await waiting)["offer"], "v=0 offer");
      },
    );

    test("something that is not a message at all is ignored", () async {
      final waiting = signaler.waitFor("offer");

      incoming.add("not json");
      incoming.add(const [1, 2, 3]);
      incoming.add(jsonEncode({"offer": "v=0 offer"}));

      expect((await waiting)["offer"], "v=0 offer");
    });

    test(
      "waiting for what never comes times out rather than hanging",
      () async {
        await expectLater(
          signaler.waitFor("answer", timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );
      },
    );
  });
}

/// A relay peer with no socket under it: [say] is that side speaking, [sent]
/// is what the relay handed back.
class _FakePeer implements RelayPeer {
  final _incoming = StreamController<Object?>();
  final sent = <String>[];
  var closed = false;

  @override
  Stream<Object?> get incoming => _incoming.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  void close() => closed = true;

  void say(Object? message) => _incoming.add(message);

  Future<void> leave() async {
    await _incoming.close();
    await pumpEventQueue();
  }
}
