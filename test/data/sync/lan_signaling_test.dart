import "dart:convert";
import "dart:io";

import "package:agent_chat/core/platform/io/signaling_server.dart";
import "package:agent_chat/data/sync/signaling/lan_signaler.dart";
import "package:flutter_test/flutter_test.dart";

/// The LAN rendezvous over a real socket: a real `HttpServer` on localhost
/// and the real client dialing it. Nothing here is faked, because the whole
/// of what this layer does is speak HTTP to another machine — a fake would
/// only ever prove the fake, and the two halves shipped with nothing between
/// them at all.
void main() {
  late SignalingServer server;
  late LanSignaler client;
  late int port;

  setUp(() async {
    server = SignalingServer();
    port = await server.start();
    client = LanSignaler();
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  /// The host's half: answer the first offer that arrives.
  void answerWith(String sdp) =>
      server.offers.listen((offer) => server.postAnswer(offer.id, sdp));

  Future<HttpClientResponse> raw(String path,
      {String method = "GET", Map<String, Object?>? body}) async {
    final http = HttpClient();
    final request =
        await http.openUrl(method, Uri.parse("http://127.0.0.1:$port$path"));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    http.close();
    return response;
  }

  test("an armed code lets an offer through and carries the answer back",
      () async {
    server.arm("123456");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      hosts: ["127.0.0.1"],
      ports: [port],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("the offer arrives as the joiner sent it", () async {
    server.arm("123456");
    final seen = <String>[];
    server.offers.listen((offer) {
      seen.add(offer.sdp);
      server.postAnswer(offer.id, "v=0 answer");
    });

    await client.exchange(
      hosts: ["127.0.0.1"],
      ports: [port],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(seen, ["v=0 offer"]);
  });

  test("a wrong code is refused", () async {
    server.arm("123456");
    answerWith("v=0 answer");

    await expectLater(
      client.exchange(
          hosts: ["127.0.0.1"],
          ports: [port],
          code: "000000",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  test("a disarmed window refuses everything", () async {
    server.arm("123456");
    server.disarm();
    answerWith("v=0 answer");

    await expectLater(
      client.exchange(
          hosts: ["127.0.0.1"],
          ports: [port],
          code: "123456",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  test("a reconnect token dials without a pairing window open", () async {
    // No `arm`: a paired device redials on the token alone.
    server.allowReconnect("tok");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      hosts: ["127.0.0.1"],
      ports: [port],
      token: "tok",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("the offer says which token let it in", () async {
    // A reconnect's handshake runs against that pair's secret, and the token
    // is the only thing in the request that says which pair it is.
    server.allowReconnect("tok");
    final seen = <String?>[];
    server.offers.listen((offer) {
      seen.add(offer.token);
      server.postAnswer(offer.id, "v=0 answer");
    });

    await client.exchange(
        hosts: ["127.0.0.1"], ports: [port], token: "tok", offerSdp: "v=0 offer");

    expect(seen, ["tok"]);
  });

  test("an offer that used the window's code carries no token", () async {
    server.arm("123456");
    final seen = <String?>[];
    server.offers.listen((offer) {
      seen.add(offer.token);
      server.postAnswer(offer.id, "v=0 answer");
    });

    await client.exchange(
        hosts: ["127.0.0.1"], ports: [port], code: "123456", offerSdp: "v=0 offer");

    expect(seen, [null]);
  });

  test("an unknown token is refused", () async {
    server.allowReconnect("tok");
    answerWith("v=0 answer");

    await expectLater(
      client.exchange(
          hosts: ["127.0.0.1"],
          ports: [port],
          token: "other",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  test("a device that moved port is found at the next one tried", () async {
    // What a reconnect does: the port it was last seen on, then the one it
    // would normally be on. An ephemeral port does not survive a restart, so
    // the first is refused and the address a peer stored is worthless without
    // the second.
    server.allowReconnect("tok");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      hosts: ["127.0.0.1"],
      ports: [port + 1, port],
      token: "tok",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("a dead address is passed over for one that answers", () async {
    server.arm("123456");
    answerWith("v=0 answer");

    final answer = await client.exchange(
      // A host that refuses the connection outright, then the real one.
      hosts: ["127.0.0.2", "127.0.0.1"],
      ports: [port],
      code: "123456",
      offerSdp: "v=0 offer",
    );

    expect(answer, "v=0 answer");
  });

  test("with nothing reachable it says so rather than hanging", () async {
    await expectLater(
      client.exchange(
          hosts: ["127.0.0.2"],
          ports: [port],
          code: "123456",
          offerSdp: "v=0 offer"),
      throwsA(isA<SignalingException>()),
    );
  });

  group("what a browser needs before it will dial a LAN address", () {
    test("the preflight answers the private-network header", () async {
      final response = await raw("/entoli/offer", method: "OPTIONS");

      expect(response.statusCode, anyOf(200, 204));
      expect(response.headers.value("access-control-allow-origin"), "*");
      expect(response.headers.value("access-control-allow-private-network"),
          "true");
    });

    test("an ordinary response carries CORS too", () async {
      final response = await raw("/entoli/health");

      expect(response.statusCode, 200);
      expect(response.headers.value("access-control-allow-origin"), "*");
    });
  });

  test("health says this is still the Entoli server", () async {
    expect(await client.alive(host: "127.0.0.1", port: port), isTrue);
  });

  test("health on a port nothing is on is false, not a throw", () async {
    await server.close();
    expect(await client.alive(host: "127.0.0.1", port: port), isFalse);
  });

  test("the bound port is the one the QR would carry", () async {
    expect(server.port, port);
    await server.close();
    expect(server.port, isNull);
  });
}
