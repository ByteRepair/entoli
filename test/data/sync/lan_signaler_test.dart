import "dart:async";
import "dart:convert";

import "package:agent_chat/data/sync/handshake.dart";
import "package:agent_chat/data/sync/signaling/lan_signaler.dart";
import "package:agent_chat/domain/sync/signaling_routes.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

/// The joiner's half, dialling the real [SignalingRoutes] the host's half is
/// made of — over a fake LAN rather than a socket, so both halves are still
/// checked against each other and a suite run still binds nothing.
void main() {
  late SignalingRoutes host;

  /// Which addresses answer. Anything else refuses the connection, which is
  /// what dialling a device that is not there does.
  late Map<String, SignalingRoutes> lan;

  /// Addresses that neither answer nor refuse: a network this device is not
  /// on drops the connect, and only a timeout ends it.
  late Set<String> silent;

  late LanSignaler client;

  setUp(() {
    host = SignalingRoutes(patience: const Duration(seconds: 2));
    lan = {"192.168.1.5:47921": host};
    silent = {};
    client = LanSignaler(
      probeTimeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        final address = "${request.url.host}:${request.url.port}";
        if (silent.contains(address)) return Completer<http.Response>().future;
        final routes = lan[address];
        if (routes == null) {
          throw http.ClientException("connection refused", request.url);
        }
        final reply = await routes.handle(SignalingRequest(
            request.method, request.url.path,
            body: request.body));
        return http.Response(reply.body, reply.status, headers: reply.headers);
      }),
    );
  });

  tearDown(() async {
    await host.close();
  });

  /// The host's half: answer the first offer that arrives.
  void answerWith(String sdp) =>
      host.offers.listen((offer) => host.postAnswer(offer.id, sdp));

  test("an armed code gets an offer through and the answer back", () async {
    host.arm("123456");
    answerWith("v=0 answer");

    final result = await client.exchange(
      addresses: ["192.168.1.5:47921"],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(result.answer, "v=0 answer");
    expect(result.address, "192.168.1.5:47921");
  });

  test("the offer arrives as it was sent", () async {
    host.arm("123456");
    final seen = <String>[];
    host.offers.listen((offer) {
      seen.add(offer.sdp);
      host.postAnswer(offer.id, "v=0 answer");
    });

    await client.exchange(
        addresses: ["192.168.1.5:47921"],
        code: "123456",
        offerSdp: "v=0 offer");

    expect(seen, ["v=0 offer"]);
  });

  test("a refusal is reported rather than returned as an answer", () async {
    host.arm("123456");
    answerWith("v=0 answer");

    await expectLater(
      client.exchange(
          addresses: ["192.168.1.5:47921"],
          code: "000000",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  test("a device that moved port is found at the next one tried", () async {
    // What a reconnect does: the port it was last seen on, then the one it
    // would normally be on. An ephemeral port does not survive a restart, so
    // the first is refused and the address a peer stored is worthless without
    // the second.
    host.allowReconnect("tok");
    answerWith("v=0 answer");

    final result = await client.exchange(
      addresses: ["192.168.1.5:51234", "192.168.1.5:47921"],
      token: "tok",
      offerSdp: "v=0 offer",
    );

    expect(result.address, "192.168.1.5:47921");
  });

  test("an address that never answers does not hold up one that does",
      () async {
    // The Tailscale case: the QR's LAN address is on a network the joiner is
    // not on, and the one that works is listed after it.
    silent = {"192.168.1.4:47921"};
    lan = {"100.101.102.103:47921": host};
    host.arm("123456");
    answerWith("v=0 answer");

    final result = await client.exchange(
      addresses: ["192.168.1.4:47921", "100.101.102.103:47921"],
      code: "123456",
      offerSdp: "v=0 offer",
    ).timeout(const Duration(seconds: 1));

    expect(result.address, "100.101.102.103:47921");
  });

  test("a reconnect's token goes to the peer and to nobody else", () async {
    // What a scan finds: another Entoli, and something answering 200 to
    // anything. Neither can prove it holds the token, so neither is sent it.
    final stranger = SignalingRoutes();
    addTearDown(stranger.close);
    final bodies = <String, String>{};
    client = LanSignaler(
      probeTimeout: const Duration(milliseconds: 100),
      client: MockClient((request) async {
        final address = "${request.url.host}:${request.url.port}";
        bodies[address] = "${bodies[address] ?? ""}${request.body}";
        if (address == "192.168.1.8:47921") {
          return http.Response(jsonEncode({"proof": "x", "sdp": "x"}), 200);
        }
        final routes = {"192.168.1.9:47921": stranger, ...lan}[address]!;
        final reply = await routes.handle(SignalingRequest(
            request.method, request.url.path,
            body: request.body));
        return http.Response(reply.body, reply.status, headers: reply.headers);
      }),
    );
    host.allowReconnect("tok");
    answerWith("v=0 answer");

    final result = await client.exchange(
      addresses: ["192.168.1.8:47921", "192.168.1.9:47921", "192.168.1.5:47921"],
      token: "tok",
      offerSdp: "v=0 offer",
    );

    expect(result.address, "192.168.1.5:47921");
    expect(bodies["192.168.1.8:47921"], isNot(contains("tok")));
    expect(bodies["192.168.1.9:47921"], isNot(contains("tok")));
    expect(bodies["192.168.1.5:47921"], contains("tok"));
  });

  test("a peer too old to have the probe is a version mismatch", () async {
    client = LanSignaler(
        client: MockClient((request) async => http.Response("", 404)));

    await expectLater(
      client.exchange(
          addresses: ["192.168.1.5:47921"],
          token: "tok",
          offerSdp: "v=0 offer"),
      throwsA(isA<ProtocolMismatchException>()),
    );
  });

  test("with nothing reachable it says so rather than hanging", () async {
    silent = {"192.168.1.3:47921"};
    await expectLater(
      client.exchange(
          addresses: ["192.168.1.3:47921", "192.168.1.4:47921"],
          code: "123456",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  test("a 200 with no answer in it is a failure, not an empty answer",
      () async {
    client = LanSignaler(
        client:
            MockClient((request) async => http.Response(jsonEncode({}), 200)));

    await expectLater(
      client.exchange(
          addresses: ["192.168.1.5:47921"],
          code: "123456",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });
}
