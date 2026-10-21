import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../../../domain/sync/signaling_routes.dart";

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
  /// would otherwise answer the same reconnect twice.
  Future<({String answer, String address})> exchange({
    required List<String> addresses,
    String code = "",
    String token = "",
    required String offerSdp,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    Object? last;
    await for (final address
        in Stream.fromFutures(addresses.toSet().map(_probe))) {
      if (address == null) continue;
      try {
        return (
          answer: await _exchange(address, code, token, offerSdp, timeout),
          address: address,
        );
      } catch (error) {
        last = error;
      }
    }
    throw SignalingException(
        "could not reach the other device${last == null ? "" : ": $last"}");
  }

  // shortcut: the timeout abandons the connect rather than cancelling it, so
  // a dead address holds a socket until the OS gives up; fine at a /24.
  Future<String?> _probe(String address) async {
    try {
      final response = await client
          .get(Uri.parse("http://$address${SignalingRoutes.healthPath}"))
          .timeout(probeTimeout);
      return response.statusCode == 200 ? address : null;
    } catch (_) {
      return null;
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

/// Every other address in the /24 of each private IPv4 address in [own]:
/// where a paired device whose saved addresses have all gone stale may now
/// be. Public and CGNAT (100.64/10, Tailscale's) addresses are not scanned —
/// those are not a LAN, and a tailnet address does not move anyway.
// shortcut: assumes a /24, since NetworkInterface gives no prefix length;
// a wider home network finds only the neighbours in this device's /24.
List<String> lanNeighbours(List<String> own) {
  final hosts = <String>{};
  for (final address in own) {
    final octets = address.split(".").map(int.tryParse).toList();
    if (octets.length != 4 || octets.contains(null)) continue;
    final [a!, b!, c!, _] = octets;
    final private = a == 10 ||
        (a == 172 && b >= 16 && b < 32) ||
        (a == 192 && b == 168);
    if (!private) continue;
    for (var d = 1; d < 255; d++) {
      hosts.add("$a.$b.$c.$d");
    }
  }
  return hosts.difference(own.toSet()).toList();
}

class SignalingException implements Exception {
  const SignalingException(this.message);
  final String message;

  @override
  String toString() => message;
}
