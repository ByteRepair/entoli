// HTTP + SSE client for the opencode server.
//
// REST: session create/list, message send, abort, permissions.
// SSE: `/event` stream drives real-time UI updates.
import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;

import "../../domain/models.dart";
import "opencode_models.dart";

class OpencodeClient {
  OpencodeClient({
    required this.baseUrl,
    this.username,
    this.password,
    http.Client? httpClient,
  }) : _http = httpClient;

  final Uri baseUrl;
  final String? username;
  final String? password;

  http.Client? _http;
  http.Client get _client => _http ??= http.Client();

  Map<String, String> get _headers => {
        "Content-Type": "application/json",
        if (password != null) ..._basicAuthHeaders(username ?? "opencode", password!),
      };

  Future<void> close() async {
    _http?.close();
    _http = null;
  }

  // --- health ---

  Future<Map<String, dynamic>> health() async {
    final r = await _client.get(baseUrl.resolve("/global/health"), headers: _headers);
    return _decode(r);
  }

  // --- sessions ---

  Future<OcSession> createSession({String? title}) async {
    final body = <String, dynamic>{};
    if (title != null) body["title"] = title;
    final r = await _client.post(
      baseUrl.resolve("/session"),
      headers: _headers,
      body: jsonEncode(body),
    );
    return OcSession.fromJson(_decode(r));
  }

  Future<void> deleteSession(String id) async {
    _expectOk(await _client.delete(baseUrl.resolve("/session/$id"), headers: _headers));
  }

  Future<void> abortSession(String id) async {
    _expectOk(await _client.post(
      baseUrl.resolve("/session/$id/abort"),
      headers: _headers,
      body: "{}",
    ));
  }

  /// Fire a prompt asynchronously (no wait). Returns immediately.
  Future<void> promptAsync(
    String sessionId, {
    required String text,
    String? model,
    String? provider,
    List<String> agents = const [],
  }) async {
    final body = <String, dynamic>{
      "parts": [
        for (final agent in agents) {"type": "agent", "name": agent},
        {"type": "text", "text": text},
      ],
    };
    // The endpoint rejects the whole request unless `model` is a
    // {providerID, modelID} pair, so send it only when both are known.
    if (model != null && provider != null) {
      body["model"] = {"providerID": provider, "modelID": model};
    }
    _expectOk(await _client.post(
      baseUrl.resolve("/session/$sessionId/prompt_async"),
      headers: _headers,
      body: jsonEncode(body),
    ));
  }

  /// Run one of the server's commands. The response only arrives once the turn
  /// it starts is over, so callers must already be streaming events by then —
  /// unlike [promptAsync], which returns as soon as the prompt is accepted.
  Future<void> runCommand(
    String sessionId, {
    required String name,
    required String arguments,
    String? model,
    String? provider,
  }) async {
    final body = <String, dynamic>{"command": name, "arguments": arguments};
    // This endpoint takes one "provider/model" string, not the pair
    // `prompt_async` insists on.
    if (model != null && provider != null) body["model"] = "$provider/$model";
    _expectOk(await _client.post(
      baseUrl.resolve("/session/$sessionId/command"),
      headers: _headers,
      body: jsonEncode(body),
    ));
  }

  /// Inject context without triggering an AI response.
  Future<void> injectContext(String sessionId, String text) async {
    _expectOk(await _client.post(
      baseUrl.resolve("/session/$sessionId/message"),
      headers: _headers,
      body: jsonEncode({
        "noReply": true,
        "parts": [
          {"type": "text", "text": text},
        ],
      }),
    ));
  }

  // --- permissions ---

  Future<void> respondPermission(String sessionId, String permissionId, String response) async {
    _expectOk(await _client.post(
      baseUrl.resolve("/session/$sessionId/permissions/$permissionId"),
      headers: _headers,
      body: jsonEncode({"response": response}),
    ));
  }

  // --- providers / models ---

  Future<List<Map<String, dynamic>>> providers() async {
    final r = await _client.get(baseUrl.resolve("/provider"), headers: _headers);
    final decoded = _decode(r);
    if (decoded is Map) {
      final all = decoded["all"];
      if (all is List) return all.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // --- commands / agents ---

  Future<List<Map<String, dynamic>>> completions(CompletionKind kind) async {
    final path = switch (kind) {
      CompletionKind.command => "/command",
      CompletionKind.agent => "/agent",
    };
    final decoded = _decode(await _client.get(baseUrl.resolve(path), headers: _headers));
    return decoded is List ? decoded.cast<Map<String, dynamic>>() : [];
  }

  // --- SSE event stream ---

  /// Connects to `/event` and yields parsed events until the stream closes.
  /// Callers must await this before prompting: opencode never replays events,
  /// so anything emitted before the stream is attached is lost for good.
  Future<Stream<OcEvent>> connectEvents() async {
    final request = http.Request("GET", baseUrl.resolve("/event"));
    if (password != null) {
      request.headers["Authorization"] = _basicAuthValue(username ?? "opencode", password!);
    }
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      throw http.ClientException("SSE connection failed: ${response.statusCode}");
    }
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    // A closed connection is how a stream ends on dispose, not an error.
    return parseSseEvents(lines).handleError((_) {}, test: (e) => e is http.ClientException);
  }

  // --- helpers ---

  /// Throws on a failed write. Without this a rejected prompt (say, a model
  /// the provider no longer offers) looks exactly like a silent stall.
  void _expectOk(http.Response r) {
    if (r.statusCode >= 400) {
      throw http.ClientException("HTTP ${r.statusCode}: ${r.body}");
    }
  }

  dynamic _decode(http.Response r) {
    _expectOk(r);
    if (r.body.isEmpty) return null;
    return jsonDecode(r.body);
  }

  static Map<String, String> _basicAuthHeaders(String user, String pass) {
    return {"Authorization": _basicAuthValue(user, pass)};
  }

  static String _basicAuthValue(String user, String pass) {
    final creds = base64Encode(utf8.encode("$user:$pass"));
    return "Basic $creds";
  }
}