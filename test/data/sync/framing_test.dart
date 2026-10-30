import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:agent_chat/data/sync/channel.dart";
import "package:agent_chat/data/sync/framing.dart";
import "package:agent_chat/data/sync/handshake.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";

/// The AEAD layer, over a pair of channels that are wired to each other and
/// otherwise do nothing. What is worth pinning here is what no single-message
/// test would show: that the counter, the nonce and the order on the wire
/// still agree when several sends are in flight at once — which they are, all
/// the time, since a turn publishes what it is doing while the records it
/// wrote are still going out.
void main() {
  /// Two ends of one encrypted channel, handshaken for real.
  Future<(SecureChannel, SecureChannel)> connected() async {
    final links = loopbackPair();
    const psk = "cGFpcmluZy1zZWNyZXQtZm9yLWEtdGVzdA";
    final a = SecureChannel.open(
      links.$1,
      handshake: Handshake(
        await SyncIdentity.load(FakeSecretStore()),
        pairingSecret: psk,
        name: "a",
      ),
      initiator: true,
    );
    final b = SecureChannel.open(
      links.$2,
      handshake: Handshake(
        await SyncIdentity.load(FakeSecretStore()),
        pairingSecret: psk,
        name: "b",
      ),
      initiator: false,
    );
    final both = await Future.wait([a, b]);
    return (both[0], both[1]);
  }

  test("a different protocol version is refused, and told so", () async {
    final links = loopbackPair();
    final told = ChannelReader(links.$1);
    final joined = Handshake(
      await SyncIdentity.load(FakeSecretStore()),
      pairingSecret: "cGFpcmluZy1zZWNyZXQtZm9yLWEtdGVzdA",
    ).run(links.$2, initiator: false, reader: ChannelReader(links.$2));
    // A future build: the version, and a shape this one has never seen.
    await links.$1.send(utf8.encode(jsonEncode({"v": 99, "role": "i"})));

    await expectLater(joined, throwsA(isA<ProtocolMismatchException>()));
    final note =
        jsonDecode(utf8.decode(await told.next())) as Map<String, dynamic>;
    expect(note["v"], SyncIdentity.protocolVersion);
    expect(
      () => Handshake.parse(jsonEncode(note..["v"] = 99)),
      throwsA(
        isA<ProtocolMismatchException>().having(
          (e) => e.message,
          "message",
          contains("please update"),
        ),
      ),
    );
  });

  test("a peer claiming an id its key does not stand for is refused", () async {
    final links = loopbackPair();
    final victim = await SyncIdentity.load(FakeSecretStore());
    final attacker = await SyncIdentity.load(FakeSecretStore());
    final joined = Handshake(
      await SyncIdentity.load(FakeSecretStore()),
      pairingSecret: "cGFpcmluZy1zZWNyZXQtZm9yLWEtdGVzdA",
    ).run(links.$2, initiator: false, reader: ChannelReader(links.$2));
    await links.$1.send(
      utf8.encode(
        jsonEncode({
          "v": SyncIdentity.protocolVersion,
          "role": "i",
          "id": victim.id,
          "pk": attacker.publicKeyB64,
          "eph": base64Encode(List.filled(32, 9)),
          "name": "x",
        }),
      ),
    );

    await expectLater(
      joined,
      throwsA(
        isA<HandshakeException>().having(
          (e) => e.message,
          "message",
          "peer id does not match its key",
        ),
      ),
    );
  });

  test("what one end seals, the other opens", () async {
    final (a, b) = await connected();
    addTearDown(a.close);
    b.listen();

    final read = b.jsonIncoming.first;
    await a.sendJson({"t": "hello"});

    expect(await read, {"t": "hello"});
  });

  test("sends in flight at once stay whole, and in order", () async {
    final (a, b) = await connected();
    addTearDown(a.close);
    b.listen();

    // Not awaited between, which is exactly how the hub sends: a turn's state
    // goes out while its records still are. Two seals overlapping took the
    // same counter, so two frames went out under one nonce — a broken MAC at
    // this end, and in ChaCha20-Poly1305 the one thing a nonce must not do.
    final read = b.jsonIncoming.take(50).toList();
    for (var i = 0; i < 50; i++) {
      unawaited(a.sendJson({"n": i}));
    }

    expect((await read).map((m) => m["n"]), List.generate(50, (i) => i));
  });

  test("a big payload and a small one do not overtake each other", () async {
    final (a, b) = await connected();
    addTearDown(a.close);
    b.listen();

    // The big one takes longer to seal, so without a queue it lands second.
    final read = b.jsonIncoming.take(2).toList();
    unawaited(a.sendJson({"big": "x" * 200000}));
    unawaited(a.sendJson({"small": 1}));

    final got = await read;
    expect(got.first.containsKey("big"), isTrue);
    expect(got.last.containsKey("small"), isTrue);
  });

  test("a message past one frame goes in pieces and arrives whole", () async {
    final links = loopbackPair();
    final sizes = <int>[];
    links.$1.watchSends(sizes.add);
    const psk = "cGFpcmluZy1zZWNyZXQtZm9yLWEtdGVzdA";
    final both = await Future.wait([
      SecureChannel.open(
        links.$1,
        handshake: Handshake(
          await SyncIdentity.load(FakeSecretStore()),
          pairingSecret: psk,
          name: "a",
        ),
        initiator: true,
      ),
      SecureChannel.open(
        links.$2,
        handshake: Handshake(
          await SyncIdentity.load(FakeSecretStore()),
          pairingSecret: psk,
          name: "b",
        ),
        initiator: false,
      ),
    ]);
    final (a, b) = (both[0], both[1]);
    addTearDown(a.close);
    b.listen();
    sizes.clear();

    final read = b.jsonIncoming.take(2).toList();
    unawaited(a.sendJson({"big": "x" * 200000}));
    unawaited(a.sendJson({"small": 1}));

    final got = await read;
    expect(got.first["big"], "x" * 200000);
    expect(got.last["small"], 1);
    expect(sizes.length, greaterThan(4));
    expect(sizes.every((size) => size <= 64 * 1024), isTrue);
  });

  test("the type byte is what a frame is authenticated against", () async {
    final (a, b) = await connected();
    addTearDown(a.close);
    b.listen();

    final read = b.incoming.first;
    await a.sendBinary(Uint8List.fromList(utf8.encode("raw")));

    expect(utf8.decode(await read), "raw");
  });
}
