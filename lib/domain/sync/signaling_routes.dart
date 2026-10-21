import "dart:async";
import "dart:convert";

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
  const SignalingReply(this.status, {this.headers = const {}, this.body = ""});

  final int status;
  final Map<String, String> headers;
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

  /// The routes. Named because the io side asks about them too.
  static const healthPath = "/entoli/health";
  static const probePath = "/entoli/probe";
  static const offerPath = "/entoli/offer";
  static const answerPath = "/entoli/answer";

  /// What either side of a probe proves it holds [token] with, over the
  /// dialler's fresh [nonce]: the dialler's [label] is "probe", the host's
  /// "host", so neither answer can be replayed as the other.
  static String proof(String token, String label, String nonce) =>
      base64Url.encode(Hmac(sha256, utf8.encode(token))
          .convert(utf8.encode("$label:$nonce"))
          .bytes);

  /// Which requests carry a body worth reading. Asked before one is drained:
  /// the io side binds a well-known port on every interface, so a POST to a
  /// path that is not one of these is the ordinary case, not the exception.
  static bool carriesBody(String method, String path) =>
      method == "POST" &&
      (path == offerPath || path == answerPath || path == probePath);

  /// Permissive CORS plus Chrome's Private-Network preflight answer: a browser
  /// tab served from anywhere must be able to dial this server on the LAN it
  /// sits on.
  static const cors = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Max-Age": "600",
  };

  Future<SignalingReply> handle(SignalingRequest request) async {
    if (request.method == "OPTIONS") {
      return const SignalingReply(204, headers: {
        ...cors,
        "Access-Control-Allow-Private-Network": "true",
      });
    }
    return switch (request.path) {
      healthPath => const SignalingReply(200, headers: cors),
      probePath => _probe(request),
      answerPath => _answer(request),
      offerPath => _offer(request),
      _ => const SignalingReply(404, headers: cors),
    };
  }

  /// Answers a reconnect's probe only for a token this host holds, and with
  /// proof of it, so a dialler sends its token to the peer and to nobody
  /// else on the network. Stops an impostor, not an observer on the path:
  /// the offer that follows is cleartext either way.
  SignalingReply _probe(SignalingRequest request) {
    if (request.method != "POST") {
      return const SignalingReply(405, headers: cors);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final nonce = body["nonce"] as String? ?? "";
    if (nonce.isEmpty) return const SignalingReply(400, headers: cors);
    for (final token in _tokens) {
      if (proof(token, "probe", nonce) == body["proof"]) {
        return SignalingReply(200,
            headers: cors,
            body: jsonEncode({"proof": proof(token, "host", nonce)}));
      }
    }
    return const SignalingReply(403, headers: cors);
  }

  SignalingReply _answer(SignalingRequest request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    postAnswer(body["id"] as String? ?? "", body["sdp"] as String? ?? "");
    return const SignalingReply(200, headers: cors);
  }

  /// Validates the code or reconnect token and nothing else — it only gates
  /// who can make the host do work. Everything the channel later needs is
  /// authenticated by the pairing secret in the handshake, so a stranger who
  /// guesses either has bought themselves a connection nobody accepts.
  Future<SignalingReply> _offer(SignalingRequest request) async {
    if (request.method != "POST") {
      return const SignalingReply(405, headers: cors);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final sdp = body["sdp"] as String?;
    final token = body["token"] as String?;
    final accepted = sdp != null &&
        ((token != null && _tokens.contains(token)) ||
            (_code != null && _code!.isNotEmpty && body["code"] == _code));
    if (!accepted) return const SignalingReply(403, headers: cors);

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
          headers: cors, body: jsonEncode({"sdp": answer}));
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
