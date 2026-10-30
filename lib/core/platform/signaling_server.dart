import "dart:async";
import "dart:convert";
import "dart:io";

import "../../domain/sync/lan_signaling.dart";
import "../log.dart";
import "../../domain/sync/signaling_routes.dart";

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
        InternetAddress.anyIPv4,
        preferredSignalingPort,
      );
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(_handle, onError: (_) {});
    await _listenForDiscovery(server.port);
    return server.port;
  }

  /// The one UDP socket, on the usual port: it answers other devices'
  /// probes and is what [discover] broadcasts from, so its replies come back
  /// to the port a firewall rule opens rather than to an ephemeral one a
  /// stateful firewall cannot match to a broadcast. Only a probe for a token
  /// this server holds gets a reply, so the port is no use for reflecting
  /// traffic at anyone.
  Future<void> _listenForDiscovery(int httpPort) async {
    try {
      final udp = _udp =
          await RawDatagramSocket.bind(
              InternetAddress.anyIPv4,
              preferredSignalingPort,
            )
            ..broadcastEnabled = true;
      udp.listen((event) {
        final datagram = event == RawSocketEvent.read ? udp.receive() : null;
        if (datagram == null) return;
        try {
          final message =
              jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
          final answer = _routes.answerProbe(message);
          if (answer != null) {
            udp.send(
              utf8.encode(jsonEncode({...answer, "port": httpPort})),
              datagram.address,
              datagram.port,
            );
          } else {
            for (final heard in [..._discoveries]) {
              heard(datagram.address.address, message);
            }
          }
        } catch (_) {
          // Anything else on the LAN may send to this port; traffic, not a
          // failure.
        }
      });
    } catch (error) {
      logFailure(
        "sync",
        "no LAN discovery on udp $preferredSignalingPort",
        error,
      );
    }
  }

  /// The [discover]s waiting on replies, each handed every datagram that is
  /// not a probe.
  final _discoveries = <void Function(String from, Map<String, dynamic>)>{};

  @override
  Future<List<String>> discover(String token) async {
    await start();
    final udp = _udp;
    if (udp == null) return const [];
    final own = await addresses();
    final (:probe, :isAnswer) = SignalingRoutes.probeFor(token);
    final found = <String>{};
    void heard(String from, Map<String, dynamic> reply) {
      if (!own.contains(from) && isAnswer(reply) && reply["port"] is int) {
        found.add("$from:${reply["port"]}");
      }
    }

    _discoveries.add(heard);
    try {
      final payload = utf8.encode(jsonEncode(probe));
      for (final to in lanBroadcasts(own)) {
        try {
          udp.send(payload, InternetAddress(to), preferredSignalingPort);
        } catch (error) {
          logFailure("sync", "could not broadcast to $to", error);
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    } finally {
      _discoveries.remove(heard);
    }
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
    try {
      final reply = await _routes.handle(
        SignalingRequest(
          request.method,
          request.uri.path,
          body: SignalingRoutes.carriesBody(request.method, request.uri.path)
              ? await utf8.decodeStream(request)
              : "",
        ),
      );
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
