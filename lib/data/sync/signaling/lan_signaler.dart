import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../../../domain/sync/lan_signaling.dart" show preferredSignalingPort;
import "../../../domain/sync/signaling_routes.dart";
import "../handshake.dart" show ProtocolMismatchException;

/// The joiner's half of a LAN exchange: find which of [exchange]'s addresses
/// answers, POST the offer there, and wait in the same request for the host's
/// answer — one round trip, no polling.
///
/// The [client] is the caller's: a dial borrows the pairing's one client and
/// this class has no lifetime of its own to close it at. Owning one here
/// behind an optional parameter had `close()` shutting the pairing's shared
/// client off after the first dial.
class LanSignaler {
  LanSignaler({required this.client, this.probeTimeout = const Duration(seconds: 3)});

  final http.Client client;

  /// How long an address gets to answer the health route. An address on a
  /// network this device is not on drops rather than refuses, and tried one
  /// at a time under the offer's own timeout, a QR naming two dead ones
  /// outlasted the host's patience before the live one was reached.
  final Duration probeTimeout;

  /// Probes every `host:port` in [addresses] at once and posts [offerSdp] —
  /// under [code], or for a reconnect the [token] derived from this pair's
  /// secret — to each that answers, in the order they answered, until one
  /// takes it. Returns the answer SDP and the address that gave it.
  ///
  /// The offer itself goes to one address at a time: a host reachable on two
  /// would otherwise answer the same reconnect twice. A reconnect's probe
  /// has the host prove it holds [token] first, since a scan reaches whoever
  /// is on the LAN and the token admits offers at the peer and its relay room.
  Future<({String answer, String address})> exchange({
    required List<String> addresses,
    String code = "",
    String token = "",
    required String offerSdp,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    Object? last;
    var outdated = false;
    await for (final (address, status) in Stream.fromFutures(
        addresses.toSet().map((address) => _probe(address, token)))) {
      // A build before the probe route answers it 404, and would refuse the
      // handshake on its version anyway.
      if (status == 404) outdated = true;
      if (status != 200) continue;
      try {
        return (
          answer: await _exchange(address, code, token, offerSdp, timeout),
          address: address,
        );
      } catch (error) {
        last = error;
      }
    }
    if (last == null && outdated) throw ProtocolMismatchException("older");
    throw SignalingException(last == null
        ? "could not reach the other device; check that its firewall allows "
            "TCP and UDP port $preferredSignalingPort"
        : "could not reach the other device: $last");
  }

  /// The address and the status it answered with, 0 where it did not; 200
  /// only from a host that proved it holds [token], where there is one.
  // shortcut: the timeout abandons the connect rather than cancelling it, so
  // a dead address holds a socket until the OS gives up; fine at a /24.
  Future<(String, int)> _probe(String address, String token) async {
    try {
      if (token.isEmpty) {
        final response = await client
            .get(Uri.parse("http://$address${SignalingRoutes.healthPath}"))
            .timeout(probeTimeout);
        return (address, response.statusCode);
      }
      final (:probe, :isAnswer) = SignalingRoutes.probeFor(token);
      final response = await client
          .post(Uri.parse("http://$address${SignalingRoutes.probePath}"),
              headers: const {"content-type": "application/json"},
              body: jsonEncode(probe))
          .timeout(probeTimeout);
      if (response.statusCode != 200) return (address, response.statusCode);
      return (address, isAnswer(jsonDecode(response.body)) ? 200 : 403);
    } catch (_) {
      return (address, 0);
    }
  }

  Future<String> _exchange(String address, String code, String token,
      String offerSdp, Duration timeout) async {
    final uri = Uri.parse("http://$address${SignalingRoutes.offerPath}");
    final response = await client
        .post(uri,
            headers: const {"content-type": "application/json"},
            body: jsonEncode({
              if (code.isNotEmpty) "code": code,
              if (token.isNotEmpty) "token": token,
              "sdp": offerSdp,
            }))
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw SignalingException(
          "the other device answered ${response.statusCode}");
    }
    final answer =
        (jsonDecode(response.body) as Map<String, dynamic>)["sdp"] as String?;
    if (answer == null || answer.isEmpty) {
      throw const SignalingException("the other device sent no answer");
    }
    return answer;
  }
}

class SignalingException implements Exception {
  const SignalingException(this.message);
  final String message;

  @override
  String toString() => message;
}
