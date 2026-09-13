import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

/// The joiner's half of a LAN exchange: POST an offer to the first address
/// that answers, and wait in the same request for the host's answer — one
/// round trip, no polling.
///
/// The [client] is the caller's: a dial borrows the pairing's one client and
/// this class has no lifetime of its own to close it at. Owning one here
/// behind an optional parameter had `close()` shutting the pairing's shared
/// client off after the first dial.
class LanSignaler {
  LanSignaler({required this.client});

  final http.Client client;

  /// Posts [offerSdp] under [code] — or, for a reconnect, under the [token]
  /// derived from this pair's secret — and returns the answer SDP. The
  /// server holds the request open until its host replies or gives up.
  /// [ports] is tried in order at each host. A reconnect passes two — where
  /// the device was last seen, then where it would normally be — since a
  /// device that has restarted is at the second and not the first.
  Future<String> exchange({
    required List<String> hosts,
    required List<int> ports,
    String code = "",
    String token = "",
    required String offerSdp,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    Object? last;
    for (final host in hosts) {
      for (final port in ports) {
        try {
          return await _exchange(host, port, code, token, offerSdp, timeout);
        } catch (error) {
          last = error;
        }
      }
    }
    throw SignalingException(
        "could not reach the other device${last == null ? "" : ": $last"}");
  }

  Future<String> _exchange(String host, int port, String code, String token,
      String offerSdp, Duration timeout) async {
    final uri = Uri.parse("http://$host:$port/entoli/offer");
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
