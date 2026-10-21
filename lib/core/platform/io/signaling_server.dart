import "dart:async";
import "dart:convert";
import "dart:io";

import "../../../domain/sync/lan_signaling.dart";
import "../../log.dart";
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
  RawDatagramSocket? _udp;

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
    await _listenForDiscovery(server.port);
    return server.port;
  }

  /// Answers [discover]'s broadcasts on the usual port, over UDP. Only a
  /// probe for a token this server holds gets a reply, so the port is no
  /// use for reflecting traffic at anyone.
  Future<void> _listenForDiscovery(int httpPort) async {
    try {
      final udp = _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, preferredSignalingPort);
      udp.listen((event) {
        final datagram = event == RawSocketEvent.read ? udp.receive() : null;
        if (datagram == null) return;
        try {
          final answer = _routes.answerProbe(
              jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>);
          if (answer == null) return;
          udp.send(utf8.encode(jsonEncode({...answer, "port": httpPort})),
              datagram.address, datagram.port);
        } catch (_) {
          // Anything else on the LAN may send to this port; traffic, not a
          // failure.
        }
      });
    } catch (error) {
      logFailure("sync", "no LAN discovery on udp $preferredSignalingPort",
          error);
    }
  }

  @override
  Future<List<String>> discover(String token) async {
    final own = await addresses();
    final (:probe, :isAnswer) = SignalingRoutes.probeFor(token);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
      ..broadcastEnabled = true;
    final found = <String>{};
    socket.listen((event) {
      final datagram = event == RawSocketEvent.read ? socket.receive() : null;
      if (datagram == null || own.contains(datagram.address.address)) return;
      try {
        final reply = jsonDecode(utf8.decode(datagram.data));
        if (isAnswer(reply) && reply["port"] is int) {
          found.add("${datagram.address.address}:${reply["port"]}");
        }
      } catch (_) {
        // Not an answer to this probe.
      }
    });
    final payload = utf8.encode(jsonEncode(probe));
    for (final to in lanBroadcasts(own)) {
      try {
        socket.send(payload, InternetAddress(to), preferredSignalingPort);
      } catch (error) {
        logFailure("sync", "could not broadcast to $to", error);
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    socket.close();
    return found.toList();
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
    _udp?.close();
    _udp = null;
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
