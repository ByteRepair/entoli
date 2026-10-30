import "dart:async";
import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

import "lan_signaling.dart";

/// One request as the rendezvous sees it.
class SignalingRequest {
  const SignalingRequest(this.method, this.path, {this.body = ""});

  final String method;
  final String path;
  final String body;
}

class SignalingReply {
  const SignalingReply(this.status, {this.body = ""});

  final int status;
  final String body;
}

/// The whole of what the LAN rendezvous decides: who is let in, which offers
/// are waiting, and what comes back. Everything a socket would add is in
/// `SignalingServer`, which is this plus `HttpServer`.
///
/// Split that way because the decisions are worth testing and the socket is
/// not: binding one in a test puts a port on the machine running the suite,
/// and the well-known port this uses in earnest is already taken whenever an
/// Entoli happens to be running there.
class SignalingRoutes {
  SignalingRoutes({this.patience = const Duration(seconds: 30)});

  /// How long an offer is held open waiting for its host to answer.
  final Duration patience;

  String? _code;

  /// Reconnect tokens: derived from stored pairing secrets, armed for the
  /// hub's lifetime so paired devices can dial again without re-pairing.
  final _tokens = <String>{};

  final _pending = <String, Completer<String>>{};
  final _offers = StreamController<IncomingOffer>.broadcast();
  var _nextId = 0;

  Stream<IncomingOffer> get offers => _offers.stream;

  void arm(String code) => _code = code;

  void disarm() => _code = null;

  void allowReconnect(String token) => _tokens.add(token);

  void refuseReconnect(String token) => _tokens.remove(token);

  void postAnswer(String id, String sdp) {
    final pending = _pending.remove(id);
    if (pending != null && !pending.isCompleted) pending.complete(sdp);
  }

  /// The routes. Named because `SignalingServer` asks about them too.
  static const healthPath = "/entoli/health";
  static const probePath = "/entoli/probe";
  static const offerPath = "/entoli/offer";

  /// What either side of a probe proves it holds [token] with, over the
  /// dialler's fresh [nonce]: the dialler's [label] is "probe", the host's
  /// "host", so neither answer can be replayed as the other.
  static String proof(String token, String label, String nonce) =>
      base64Url.encode(Hmac(sha256, utf8.encode(token))
          .convert(utf8.encode("$label:$nonce"))
          .bytes);

  /// Which requests carry a body worth reading. Asked before one is drained:
  /// the server binds a well-known port on every interface, so a POST to a
  /// path that is not one of these is the ordinary case, not the exception.
  static bool carriesBody(String method, String path) =>
      method == "POST" &&
      (path == offerPath || path == probePath);

  Future<SignalingReply> handle(SignalingRequest request) async {
    return switch (request.path) {
      healthPath => const SignalingReply(200),
      probePath => _probe(request),
      offerPath => _offer(request),
      _ => const SignalingReply(404),
    };
  }

  /// Answers a reconnect's probe only for a token this host holds, and with
  /// proof of it, so a dialler sends its token to the peer and to nobody
  /// else on the network. Stops an impostor, not an observer on the path:
  /// the offer that follows is cleartext either way.
  SignalingReply _probe(SignalingRequest request) {
    if (request.method != "POST") {
      return const SignalingReply(405);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final answer = answerProbe(body);
    return answer == null
        ? const SignalingReply(403)
        : SignalingReply(200, body: jsonEncode(answer));
  }

  /// The host's half of a probe, over HTTP or a LAN broadcast: its own proof
  /// for the token [probe] was made with, or null for one it does not hold.
  Map<String, String>? answerProbe(Map<String, dynamic> probe) {
    final nonce = probe["nonce"];
    if (nonce is! String || nonce.isEmpty) return null;
    for (final token in _tokens) {
      if (proof(token, "probe", nonce) == probe["proof"]) {
        return {"proof": proof(token, "host", nonce)};
      }
    }
    return null;
  }

  /// A dialler's probe for [token]: a fresh nonce and its proof. [isAnswer]
  /// is whether a host's reply to it proves the host holds [token] too.
  static ({Map<String, String> probe, bool Function(Object? reply) isAnswer})
      probeFor(String token) {
    final nonce =
        base64Url.encode(List.generate(16, (_) => _random.nextInt(256)));
    final host = proof(token, "host", nonce);
    return (
      probe: {"nonce": nonce, "proof": proof(token, "probe", nonce)},
      isAnswer: (reply) => reply is Map && reply["proof"] == host,
    );
  }

  static final _random = Random.secure();

  /// Validates the code or reconnect token and nothing else — it only gates
  /// who can make the host do work. Everything the channel later needs is
  /// authenticated by the pairing secret in the handshake, so a stranger who
  /// guesses either has bought themselves a connection nobody accepts.
  Future<SignalingReply> _offer(SignalingRequest request) async {
    if (request.method != "POST") {
      return const SignalingReply(405);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final sdp = body["sdp"] as String?;
    final token = body["token"] as String?;
    final accepted = sdp != null &&
        ((token != null && _tokens.contains(token)) ||
            (_code != null && _code!.isNotEmpty && body["code"] == _code));
    if (!accepted) return const SignalingReply(403);

    final id = "${_nextId++}";
    final answered = _pending[id] = Completer<String>();
    // Which token let it in travels with it: a reconnect's handshake runs
    // against that pair's secret, and only the caller knows which that is.
    _offers.add(IncomingOffer(
        id: id, sdp: sdp, token: _tokens.contains(token) ? token : null));
    try {
      final answer = await answered.future.timeout(patience,
          onTimeout: () => throw TimeoutException("no answer"));
      return SignalingReply(200,
          body: jsonEncode({"sdp": answer}));
    } finally {
      _pending.remove(id);
    }
  }

  /// Offers still waiting are failed rather than left to their [patience]:
  /// closing is the hub going away, and half a minute of nothing is not an
  /// answer anyone is still going to give.
  Future<void> close() async {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError("the rendezvous closed"));
      }
    }
    _pending.clear();
    await _offers.close();
  }
}
