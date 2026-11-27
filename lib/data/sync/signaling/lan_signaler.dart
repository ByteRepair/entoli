import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:entoli_core/model/sync/lan_signaling.dart"
    show preferredSignalingPort;
import "package:entoli_core/model/sync/signaling_routes.dart";

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
  LanSignaler({
    required this.client,
    this.probeTimeout = const Duration(seconds: 3),
  });

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
    final heard = <_Probed>{};
    await for (final (address, probed) in Stream.fromFutures(
      addresses.toSet().map((address) => _probe(address, token)),
    )) {
      heard.add(probed);
      if (probed != _Probed.ok) continue;
      try {
        return (
          answer: await _exchange(address, code, token, offerSdp, timeout),
          address: address,
        );
      } catch (error) {
        last = error;
      }
    }
    if (last == null && heard.contains(_Probed.outdated)) {
      throw ProtocolMismatchException("older");
    }
    // Only where every address answered: one that did not may be the peer,
    // and a refusal from an address another Entoli took since is no verdict.
    if (last == null &&
        heard.contains(_Probed.refused) &&
        !heard.contains(_Probed.unreached)) {
      throw const SignalingException(
        "the other device does not recognise this pairing; remove it on "
        "both devices and pair again",
      );
    }
    throw SignalingException(
      last == null
          ? "could not reach the other device; check that its firewall allows "
                "TCP and UDP port $preferredSignalingPort"
          : "could not reach the other device: $last",
    );
  }

  /// The address and what it answered: [_Probed.ok] only from a host that
  /// proved it holds [token], where there is one.
  // shortcut: the timeout abandons the connect rather than cancelling it, so
  // a dead address holds a socket until the OS gives up; fine at a /24.
  Future<(String, _Probed)> _probe(String address, String token) async {
    try {
      if (token.isEmpty) {
        final response = await client
            .get(Uri.parse("http://$address${SignalingRoutes.healthPath}"))
            .timeout(probeTimeout);
        return (address, _Probed.of(response.statusCode));
      }
      final (:probe, :isAnswer) = SignalingRoutes.probeFor(token);
      final response = await client
          .post(
            Uri.parse("http://$address${SignalingRoutes.probePath}"),
            headers: const {"content-type": "application/json"},
            body: jsonEncode(probe),
          )
          .timeout(probeTimeout);
      if (response.statusCode != 200) {
        return (address, _Probed.of(response.statusCode));
      }
      return (
        address,
        isAnswer(jsonDecode(response.body)) ? _Probed.ok : _Probed.refused,
      );
    } catch (_) {
      return (address, _Probed.unreached);
    }
  }

  Future<String> _exchange(
    String address,
    String code,
    String token,
    String offerSdp,
    Duration timeout,
  ) async {
    final uri = Uri.parse("http://$address${SignalingRoutes.offerPath}");
    final response = await client
        .post(
          uri,
          headers: const {"content-type": "application/json"},
          body: jsonEncode({
            if (code.isNotEmpty) "code": code,
            if (token.isNotEmpty) "token": token,
            "sdp": offerSdp,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw SignalingException(
        "the other device answered ${response.statusCode}",
      );
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

/// What one address said to a probe.
enum _Probed {
  ok,

  /// Nothing answered: dropped, refused, or timed out.
  unreached,

  /// A build before the probe route, which would refuse the handshake on its
  /// version anyway.
  outdated,

  /// It answered and does not hold this pair's token: reached, not blocked.
  refused,

  /// Anything else it answered.
  failed;

  static _Probed of(int status) => switch (status) {
    200 => ok,
    // The probe route's own word for a token it does not hold.
    403 => refused,
    404 => outdated,
    _ => failed,
  };
}
