import "dart:async";
import "dart:convert";
import "dart:io";

import "../../../core/log.dart";
import "../../../core/random_token.dart";
import "llm_client.dart";

/// A tool call a harness made over [McpToolBridge], held open until Entoli's
/// own loop has run the tool and [answer] hands back what it said.
class HeldToolCall {
  HeldToolCall(this.name, this.arguments);

  final String name;
  final Object? arguments;
  final _result = Completer<Map<String, dynamic>>();

  /// What a call is failed with when the session it was made in goes first.
  static const stopped = "Entoli stopped this turn";

  /// [result], a tool message, as MCP's content: its text, and its images as
  /// blocks of their own.
  void answer(LlmMessage result) {
    if (_result.isCompleted) return;
    _result.complete({
      "content": [
        {"type": "text", "text": result.text},
        for (final file in result.attachments)
          if (file.isImage)
            {"type": "image", "data": file.base64, "mimeType": file.mimeType}
          else
            {"type": "text", "text": "[attached: ${file.filename}]"},
      ],
    });
  }

  void fail(String reason) {
    if (_result.isCompleted) return;
    _result.complete({
      "content": [
        {"type": "text", "text": reason},
      ],
      "isError": true,
    });
  }
}

/// What a session hands a harness so it can reach Entoli's tools, and takes
/// down after it. The port a test fakes: [McpToolBridge] is the real one, a
/// socket around [McpToolRoutes].
abstract class ToolBridge {
  /// The `mcpServers` entry that reaches it.
  Map<String, dynamic> get config;

  /// Fails every call still held, so the harness is not left waiting, and
  /// stops answering.
  Future<void> close();
}

/// How a session gets a [ToolBridge] for its tools.
typedef BindToolBridge =
    Future<ToolBridge> Function(
      List<LlmTool> tools,
      void Function(HeldToolCall call) onCall,
    );

/// What the MCP server decides, apart from the socket that carries it: a
/// JSON-RPC request in, its answer out. Nothing runs here. A `tools/call` is
/// handed to [onCall] and its answer waits until the call is answered,
/// which is how a harness that runs its own loop is made to wait while
/// Entoli's loop — approvals, sub-agents and all — runs the tool and comes
/// back with the result.
class McpToolRoutes {
  McpToolRoutes(this.tools, this.onCall);

  /// What the server is called to the harness, and so the prefix of every
  /// tool name it shows the model: `mcp__entoli__bash`.
  static const serverName = "entoli";

  final List<LlmTool> tools;
  final void Function(HeldToolCall call) onCall;
  final _held = <HeldToolCall>{};

  /// [body]'s answer as the JSON-RPC response, or null for a notification,
  /// which is answered with nothing.
  Future<Map<String, dynamic>?> answer(Object? body) async {
    if (body is! Map || !body.containsKey("id")) return null;
    return {"jsonrpc": "2.0", "id": body["id"], ...await _answer(body)};
  }

  Future<Map<String, dynamic>> _answer(Map body) async {
    final params = body["params"] is Map ? body["params"] as Map : const {};
    switch (body["method"]) {
      case "initialize":
        return {
          "result": {
            "protocolVersion": params["protocolVersion"] ?? "2025-06-18",
            "capabilities": {
              "tools": {"listChanged": false},
            },
            "serverInfo": {"name": serverName, "version": "1"},
          },
        };
      case "ping":
        return {"result": <String, dynamic>{}};
      case "tools/list":
        return {
          "result": {
            "tools": [
              for (final tool in tools)
                {
                  "name": tool.name,
                  "description": tool.description,
                  "inputSchema": tool.schema,
                },
            ],
          },
        };
      case "tools/call":
        final call = HeldToolCall(
          params["name"] as String? ?? "",
          params["arguments"],
        );
        _held.add(call);
        onCall(call);
        try {
          return {"result": await call._result.future};
        } finally {
          _held.remove(call);
        }
      default:
        return {
          "error": {"code": -32601, "message": "No method ${body["method"]}"},
        };
    }
  }

  /// Fails every call still held.
  void failHeld() {
    for (final call in _held.toList()) {
      call.fail(HeldToolCall.stopped);
    }
  }
}

/// [McpToolRoutes] on an ephemeral loopback port, over the Streamable HTTP
/// transport's plain-JSON half: one POST, one JSON answer, no event stream.
/// A random bearer token guards it, since any process on the machine can
/// reach a loopback port.
///
/// This is the socket alone — the token check and the translation of an
/// answer into a response — and no test covers it, for the reason the sync
/// servers' adapters go uncovered: a test binds no port.
class McpToolBridge implements ToolBridge {
  McpToolBridge._(this._server, this._routes, this._token) {
    _server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object e) => logFailure("llm", "the MCP bridge failed", e),
    );
  }

  static Future<McpToolBridge> bind(
    List<LlmTool> tools,
    void Function(HeldToolCall call) onCall,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return McpToolBridge._(
      server,
      McpToolRoutes(tools, onCall),
      randomToken(32),
    );
  }

  final HttpServer _server;
  final McpToolRoutes _routes;
  final String _token;

  @override
  Map<String, dynamic> get config => {
    "type": "http",
    "url": "http://127.0.0.1:${_server.port}/mcp",
    "headers": {"Authorization": "Bearer $_token"},
  };

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value("authorization") != "Bearer $_token") {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method == "DELETE") return;
      if (request.method != "POST") {
        // No event stream is offered: everything is answered in the POST.
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final Object? body;
      try {
        body = jsonDecode(await utf8.decodeStream(request));
      } on FormatException {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final answer = await _routes.answer(body);
      if (answer == null) {
        response.statusCode = HttpStatus.accepted;
        return;
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(answer));
    } catch (e) {
      logFailure("llm", "the MCP bridge could not answer a request", e);
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close().catchError((_) {});
    }
  }

  @override
  Future<void> close() async {
    _routes.failHeld();
    await _server.close(force: true);
  }
}
