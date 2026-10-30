import "dart:async";
import "dart:convert";

import "package:agent_chat/domain/sync/signaling_routes.dart";
import "package:flutter_test/flutter_test.dart";

/// What the LAN rendezvous decides, with no socket under it. All of this used
/// to run against an `HttpServer` on localhost, which put a port on whichever
/// machine ran the suite and failed outright when an Entoli was already on the
/// well-known one.
void main() {
  late SignalingRoutes routes;

  setUp(() => routes = SignalingRoutes(patience: const Duration(seconds: 2)));
  tearDown(() => routes.close());

  Future<SignalingReply> offer({
    String? code,
    String? token,
    String sdp = "v=0 offer",
    String method = "POST",
  }) =>
      routes.handle(SignalingRequest(method, "/entoli/offer",
          body: jsonEncode({
            "code": ?code,
            "token": ?token,
            "sdp": sdp,
          })));

  /// The host's half: answer the first offer that arrives.
  void answerWith(String sdp) =>
      routes.offers.listen((offer) => routes.postAnswer(offer.id, sdp));

  String sdpOf(SignalingReply reply) =>
      (jsonDecode(reply.body) as Map<String, dynamic>)["sdp"] as String;

  test("an armed code lets an offer through and carries the answer back",
      () async {
    routes.arm("123456");
    answerWith("v=0 answer");

    final reply = await offer(code: "123456");

    expect(reply.status, 200);
    expect(sdpOf(reply), "v=0 answer");
  });

  test("the offer arrives as the joiner sent it", () async {
    routes.arm("123456");
    final seen = <String>[];
    routes.offers.listen((offer) {
      seen.add(offer.sdp);
      routes.postAnswer(offer.id, "v=0 answer");
    });

    await offer(code: "123456");

    expect(seen, ["v=0 offer"]);
  });

  test("an offer that fails its check is refused with a 403", () async {
    routes.arm("123456");
    answerWith("v=0 answer");

    // A wrong code.
    expect((await offer(code: "000000")).status, 403);

    // A window that was disarmed refuses even the right code.
    routes.disarm();
    expect((await offer(code: "123456")).status, 403);

    // Tokens: one the routes never knew, and one that was revoked.
    routes.allowReconnect("tok");
    expect((await offer(token: "other")).status, 403);
    routes.refuseReconnect("tok");
    expect((await offer(token: "tok")).status, 403);
  });

  test("a reconnect token dials without a pairing window open", () async {
    // No `arm`: a paired device redials on the token alone.
    routes.allowReconnect("tok");
    answerWith("v=0 answer");

    expect(sdpOf(await offer(token: "tok")), "v=0 answer");
  });

  test("the offer hands over what let it in: token or nothing", () async {
    // A reconnect's handshake runs against that pair's secret, and the token
    // is the only thing in the request that says which pair it is.
    routes.allowReconnect("tok");
    final seen = <String?>[];
    routes.offers.listen((offer) {
      seen.add(offer.token);
      routes.postAnswer(offer.id, "v=0 answer");
    });

    await offer(token: "tok");
    expect(seen, ["tok"]);

    // The window's code lets it in without one.
    routes.arm("123456");
    await offer(code: "123456");
    expect(seen.last, isNull);
  });

  test("an unknown token is refused", () async {
    routes.allowReconnect("tok");
    answerWith("v=0 answer");

    expect((await offer(token: "other")).status, 403);
  });

  test("a revoked token is refused again", () async {
    routes.allowReconnect("tok");
    routes.refuseReconnect("tok");
    answerWith("v=0 answer");

    expect((await offer(token: "tok")).status, 403);
  });

  test("each offer waits for its own answer", () async {
    // Two at once is a device coming back at the moment another is being
    // paired; one id per offer is what keeps them from being crossed.
    routes.arm("123456");
    final ids = <String>[];
    routes.offers.listen((offer) => ids.add(offer.id));

    final first = offer(code: "123456", sdp: "first");
    final second = offer(code: "123456", sdp: "second");
    await pumpEventQueue();
    routes.postAnswer(ids[1], "for second");
    routes.postAnswer(ids[0], "for first");

    expect(sdpOf(await first), "for first");
    expect(sdpOf(await second), "for second");
  });

  test("an offer nobody answers gives up rather than waiting forever",
      () async {
    routes = SignalingRoutes(patience: const Duration(milliseconds: 50));
    routes.arm("123456");

    await expectLater(offer(code: "123456"), throwsA(isA<TimeoutException>()));
  });

  test("closing fails an offer still waiting rather than leaving it", () async {
    routes.arm("123456");
    // Watched before the close, or the error lands with nothing holding it.
    final failed = expectLater(offer(code: "123456"), throwsA(isA<StateError>()));
    await pumpEventQueue();

    await routes.close();

    await failed;
  });

  test("a POST that carries no body is not drained for one", () {
    // The server asks before reading: it binds a well-known port on every
    // interface, so a POST to a path that is not here is the ordinary case.
    expect(SignalingRoutes.carriesBody("POST", SignalingRoutes.offerPath),
        isTrue);
    expect(SignalingRoutes.carriesBody("POST", "/wp-login.php"), isFalse);
    expect(SignalingRoutes.carriesBody("GET", SignalingRoutes.offerPath),
        isFalse);
  });

  test("an offer sent as anything but a POST is refused", () async {
    routes.arm("123456");

    expect((await offer(code: "123456", method: "GET")).status, 405);
  });

  group("the probe", () {
    Future<SignalingReply> probe(String token, String nonce) =>
        routes.handle(SignalingRequest("POST", SignalingRoutes.probePath,
            body: jsonEncode({
              "nonce": nonce,
              "proof": SignalingRoutes.proof(token, "probe", nonce),
            })));

    test("proves a token it holds, under the host's label", () async {
      routes.allowReconnect("tok");
      final reply = await probe("tok", "n1");
      expect(reply.status, 200);
      expect(jsonDecode(reply.body)["proof"],
          SignalingRoutes.proof("tok", "host", "n1"));
    });

    test("a dialler's probe is answered only by a host holding its token",
        () {
      routes.allowReconnect("tok");
      final (:probe, :isAnswer) = SignalingRoutes.probeFor("tok");
      expect(isAnswer(routes.answerProbe(probe)), isTrue);

      final other = SignalingRoutes.probeFor("other");
      expect(routes.answerProbe(other.probe), isNull);
      // An answer to one probe proves nothing to another.
      expect(other.isAnswer(routes.answerProbe(probe)), isFalse);
    });

    test("refuses a token it does not hold, or no longer does", () async {
      expect((await probe("tok", "n1")).status, 403);
      routes.allowReconnect("tok");
      routes.refuseReconnect("tok");
      expect((await probe("tok", "n1")).status, 403);
    });
  });

  test("a path that is not one of the routes is a 404", () async {
    expect(
        (await routes.handle(const SignalingRequest("GET", "/"))).status, 404);
  });
}
