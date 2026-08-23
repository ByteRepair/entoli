import "dart:convert";

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

  late LanSignaler client;

  setUp(() {
    host = SignalingRoutes(patience: const Duration(seconds: 2));
    lan = {"192.168.1.5:47921": host};
    client = LanSignaler(client: MockClient((request) async {
      final routes = lan["${request.url.host}:${request.url.port}"];
      if (routes == null) {
        throw http.ClientException("connection refused", request.url);
      }
      final reply = await routes.handle(SignalingRequest(
          request.method, request.url.path,
          body: request.body));
      return http.Response(reply.body, reply.status, headers: reply.headers);
    }));
  });

  tearDown(() async {
    client.close();
    await host.close();
  });

  /// The host's half: answer the first offer that arrives.
  void answerWith(String sdp) =>
      host.offers.listen((offer) => host.postAnswer(offer.id, sdp));

  test("an armed code gets an offer through and the answer back", () async {
    host.arm("123456");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      hosts: ["192.168.1.5"],
      ports: [47921],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("the offer arrives as it was sent", () async {
    host.arm("123456");
    final seen = <String>[];
    host.offers.listen((offer) {
      seen.add(offer.sdp);
      host.postAnswer(offer.id, "v=0 answer");
    });

    await client.exchange(
        hosts: ["192.168.1.5"],
        ports: [47921],
        code: "123456",
        offerSdp: "v=0 offer");

    expect(seen, ["v=0 offer"]);
  });

  test("a refusal is reported rather than returned as an answer", () async {
    host.arm("123456");
    answerWith("v=0 answer");

    await expectLater(
      client.exchange(
          hosts: ["192.168.1.5"],
          ports: [47921],
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

    final answer = await client.exchange(
      hosts: ["192.168.1.5"],
      ports: [51234, 47921],
      token: "tok",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("a dead address is passed over for one that answers", () async {
    host.arm("123456");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      hosts: ["192.168.1.4", "192.168.1.5"],
      ports: [47921],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("with nothing reachable it says so rather than hanging", () async {
    await expectLater(
      client.exchange(
          hosts: ["192.168.1.4"],
          ports: [47921],
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
          hosts: ["192.168.1.5"],
          ports: [47921],
          code: "123456",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });
}
