import "dart:async";
import "dart:convert";
import "dart:io";

import "../../../domain/sync/lan_signaling.dart";
import "../../../domain/sync/signaling_routes.dart";

/// The rendezvous two devices on one network meet at before WebRTC can take
/// over. Binds all interfaces on the well-known port; that and a one-time code
/// travel to the other device in the QR, never through any registry.
///
/// Four routes:
///
///   GET  /entoli/health   — is this still the Entoli signaling server
///   POST /entoli/probe    — does it hold this reconnect token, with proof
///   POST /entoli/offer    — a joiner's SDP, held open until an answer or 30s
///   POST /entoli/answer   — the host's answer, completing one waiting offer
///
/// What each of them decides is [SignalingRoutes]. All this adds is the
/// socket: bind, read the request, write the reply back.
class SignalingServer implements LanSignaling {
  SignalingServer();

  final _routes = SignalingRoutes();
  HttpServer? _server;

  @override
  Stream<IncomingOffer> get offers => _routes.offers;

  @override
  void arm(String code) => _routes.arm(code);

  @override
  void disarm() => _routes.disarm();

  @override
  void allowReconnect(String token) => _routes.allowReconnect(token);

  @override
  void refuseReconnect(String token) => _routes.refuseReconnect(token);

  @override
  void postAnswer(String id, String sdp) => _routes.postAnswer(id, sdp);

  @override
  int? get port => _server?.port;

  @override
  Future<int> start() async {
    if (_server != null) return _server!.port;
    // The usual port, so a peer holding an address from before this device
    // restarted can still guess where it went. Ephemeral where that is taken,
    // which means another Entoli is already running here: that one is then
    // the reachable one, and this one can still dial out.
    HttpServer? server;
    try {
      server = await HttpServer.bind(
          InternetAddress.anyIPv4, preferredSignalingPort);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
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
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    await _routes.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    // Before anything that can throw: a browser has to be able to read a 500
    // as well as an answer.
    SignalingRoutes.cors.forEach(response.headers.set);
    try {
      final reply = await _routes.handle(SignalingRequest(
        request.method,
        request.uri.path,
        body: SignalingRoutes.carriesBody(request.method, request.uri.path)
            ? await utf8.decodeStream(request)
            : "",
      ));
      reply.headers.forEach(response.headers.set);
      response.statusCode = reply.status;
      if (reply.body.isNotEmpty) response.write(reply.body);
    } catch (_) {
      // Throws in its own right once the headers have gone out.
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    }
    try {
      await response.close();
    } catch (_) {}
  }
}
