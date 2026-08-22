import "dart:async";
import "dart:convert";
import "dart:io";

import "../../../domain/sync/lan_signaling.dart";

/// The rendezvous two devices on one network meet at before WebRTC can take
/// over. Binds all interfaces on an ephemeral port; the port and a one-time
/// code travel to the other device in the QR, never through any registry.
///
/// Three routes:
///
///   GET  /entoli/health   — is this still the Entoli signaling server
///   POST /entoli/offer    — a joiner's SDP, held open until an answer or 30s
///   POST /entoli/answer   — the host's answer, completing one waiting offer
///
/// The offer route validates the code or reconnect token and nothing else —
/// it only gates who can make the host do work. Everything the channel later
/// needs is authenticated by the pairing secret in the handshake, so a
/// stranger who guesses either has bought themselves a connection nobody
/// accepts.
///
/// Every response carries permissive CORS plus Chrome's Private-Network
/// preflight answer: a browser tab served from anywhere must be able to dial
/// this server on the LAN it sits on.
class SignalingServer implements LanSignaling {
  SignalingServer();

  String? _code;

  /// Reconnect tokens: derived from stored pairing secrets, armed for the
  /// hub's lifetime so paired devices can dial again without re-pairing.
  final _tokens = <String>{};

  HttpServer? _server;
  final _pending = <String, Completer<String>>{};

  final _offers = StreamController<IncomingOffer>.broadcast();

  @override
  Stream<IncomingOffer> get offers => _offers.stream;

  @override
  void arm(String code) => _code = code;

  @override
  void disarm() => _code = null;

  void allowReconnect(String token) => _tokens.add(token);

  @override
  int? get port => _server?.port;

  @override
  Future<int> start() async {
    if (_server != null) return _server!.port;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (_) {});
    return server.port;
  }

  @override
  Future<List<String>> addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  }

  @override
  void postAnswer(String id, String sdp) {
    final pending = _pending.remove(id);
    if (pending != null && !pending.isCompleted) {
      pending.complete(sdp);
    }
  }

  @override
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    await _offers.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set("Access-Control-Allow-Origin", "*")
      ..set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
      ..set("Access-Control-Allow-Headers", "content-type")
      ..set("Access-Control-Max-Age", "600");
    if (request.method == "OPTIONS") {
      // Chrome asks before letting a public origin reach this private address.
      response.headers.set("Access-Control-Allow-Private-Network", "true");
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    try {
      switch (request.uri.path) {
        case "/entoli/health":
          response.statusCode = HttpStatus.ok;
          await response.close();
        case "/entoli/offer":
          await _onOffer(request, response);
        case "/entoli/answer":
          final body =
              jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
          postAnswer(body["id"] as String? ?? "", body["sdp"] as String? ?? "");
          response.statusCode = HttpStatus.ok;
          await response.close();
        default:
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _onOffer(HttpRequest request, HttpResponse response) async {
    if (request.method != "POST") {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final sdp = body["sdp"] as String?;
    final token = body["token"] as String?;
    final accepted = sdp != null &&
        ((token != null && _tokens.contains(token)) ||
            (_code != null && _code!.isNotEmpty && body["code"] == _code));
    if (!accepted) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final answered = _pending[id] = Completer<String>();
    _offers.add(IncomingOffer(id: id, sdp: sdp));
    try {
      final answer =
          await answered.future.timeout(const Duration(seconds: 30), onTimeout: () => throw TimeoutException("no answer"));
      response.write(jsonEncode({"sdp": answer}));
    } finally {
      _pending.remove(id);
    }
    await response.close();
  }
}
