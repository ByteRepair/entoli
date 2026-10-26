import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "llm_client.dart";

/// Server-sent events, reduced to the `data:` payloads. Both providers put
/// everything we need in there — Anthropic's `event:` name is repeated as the
/// payload's `type` — so the frames are all this has to understand.
Stream<String> decodeSse(Stream<List<int>> body) async* {
  final buffer = StringBuffer();
  await for (final line in body.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (buffer.isNotEmpty) yield buffer.toString();
      buffer.clear();
      continue;
    }
    if (!line.startsWith("data:")) continue;
    // A payload split across `data:` lines is rejoined with the newlines the
    // protocol strips.
    if (buffer.isNotEmpty) buffer.write("\n");
    buffer.write(line.substring(5).trimLeft());
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}

/// Append [path] to a versioned root. Appended rather than resolved against:
/// resolving `models` against `https://host/v1` would drop the version.
Uri under(Uri base, String path) {
  final root = base.toString();
  return Uri.parse("${root.endsWith("/") ? root.substring(0, root.length - 1) : root}/$path");
}

/// The ids at a `/models` endpoint. Both providers answer in OpenAI's shape.
/// One that will not answer contributes nothing rather than failing the whole
/// model list — the picker is built from every provider at once.
Future<List<String>> listModelIds(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
}) async {
  final response = await client.get(url, headers: headers);
  if (response.statusCode != 200) return const [];
  final json = jsonDecode(response.body);
  final data = json is Map<String, dynamic> ? json["data"] : null;
  if (data is! List) return const [];
  return [
    for (final entry in data)
      if (entry is Map<String, dynamic> && entry["id"] is String) entry["id"] as String,
  ];
}

/// POST [body] and hand back the streaming response, turning anything that is
/// not a 200 into an [LlmException] that says whether waiting would help.
Future<http.StreamedResponse> postStream(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  required Object body,
}) async {
  final request = http.Request("POST", url)
    ..headers.addAll(headers)
    ..body = jsonEncode(body);
  return sendChecked(client, request);
}

/// [request] sent, whatever its status. A connection that never opened is an
/// [LlmException].
Future<http.StreamedResponse> sendOrUnreachable(
    http.Client client, http.BaseRequest request) async {
  try {
    return await client.send(request);
  } catch (e) {
    // No status to judge by: a connection that never opened is worth another
    // try, and a provider that is genuinely down will exhaust the attempts.
    throw LlmException("Could not reach ${request.url}: $e", retryable: true);
  }
}

/// [postStream] for a request already built — a multipart upload.
Future<http.StreamedResponse> sendChecked(
    http.Client client, http.BaseRequest request) async {
  final response = await sendOrUnreachable(client, request);
  if (response.statusCode == 200) return response;
  final text = await response.stream.bytesToString();
  throw LlmException(
    _errorMessage(text),
    statusCode: response.statusCode,
    retryable: _retryable(response.statusCode),
  );
}

/// Rate limits and overloaded servers clear on their own; a rejected key or a
/// malformed request does not, and retrying one just delays the report.
bool _retryable(int status) =>
    status == 408 || status == 409 || status == 429 || status >= 500;

/// Both providers wrap the reason in `{"error": {"message": ...}}`; a gateway
/// in front of them may not, so the raw body is the fallback.
String _errorMessage(String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map<String, dynamic>) {
      final error = json["error"];
      if (error is Map<String, dynamic> && error["message"] is String) {
        return error["message"] as String;
      }
      if (error is String) return error;
      if (json["message"] is String) return json["message"] as String;
    }
  } catch (_) {}
  final trimmed = body.trim();
  return trimmed.isEmpty ? "The provider gave no reason." : trimmed;
}
