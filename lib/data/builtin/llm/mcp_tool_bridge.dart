import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "../../../core/log.dart";
import "llm_client.dart";

/// A tool call a harness made over [McpToolBridge], held open until Entoli's
/// own loop has run the tool and [answer] hands back what it said.
class HeldToolCall {
  HeldToolCall(this.name, this.arguments);

  final String name;
  final Object? arguments;
  final _result = Completer<Map<String, dynamic>>();

  bool get answered => _result.isCompleted;

  /// [result], a tool message, as MCP's content: its text, and its images as
  /// blocks of their own.
  void answer(LlmMessage result) {
    if (answered) return;
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
    if (answered) return;
    _result.complete({
      "content": [
        {"type": "text", "text": reason},
      ],
      "isError": true,
    });
  }
}

/// Entoli's tools as an MCP server on loopback, over the Streamable HTTP
/// transport's plain-JSON half: one POST, one JSON answer, no event stream.
///
/// It runs none of them. A `tools/call` is handed to [onCall] and its request
/// stays open until the call is answered, which is how a harness that runs
/// its own loop is made to wait while Entoli's loop — approvals, sub-agents
/// and all — runs the tool and comes back with the result.
///
/// A random bearer token guards it, since any process on the machine can
/// reach a loopback port.
class McpToolBridge {
  McpToolBridge._(this._server, this.tools, this.onCall, this.token) {
    _server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object e) => logFailure("llm", "the MCP bridge failed", e),
    );
  }

  /// Bound on an ephemeral loopback port.
  static Future<McpToolBridge> bind(
    List<LlmTool> tools,
    void Function(HeldToolCall call) onCall,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = [
      for (var i = 0; i < 32; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, "0"),
    ].join();
    return McpToolBridge._(server, tools, onCall, token);
  }

  /// What the server is called to the harness, and so the prefix of every
  /// tool name it shows the model: `mcp__entoli__bash`.
  static const serverName = "entoli";

  final HttpServer _server;
  final List<LlmTool> tools;
  final void Function(HeldToolCall call) onCall;
  final String token;
  final _held = <HeldToolCall>{};

  Uri get url => Uri.parse("http://127.0.0.1:${_server.port}/mcp");

  /// The `mcpServers` entry that reaches it.
  Map<String, dynamic> get config => {
    "type": "http",
    "url": "$url",
    "headers": {"Authorization": "Bearer $token"},
  };

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value("authorization") != "Bearer $token") {
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
      if (body is! Map || !body.containsKey("id")) {
        // A notification, which is answered with nothing.
        response.statusCode = HttpStatus.accepted;
        return;
      }
      final answer = await _answer(body);
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({"jsonrpc": "2.0", "id": body["id"], ...answer}),
      );
    } catch (e) {
      logFailure("llm", "the MCP bridge could not answer a request", e);
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close().catchError((_) {});
    }
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

  /// Fails every call still held, so the harness is not left waiting, and
  /// stops listening.
  Future<void> close() async {
    for (final call in _held.toList()) {
      call.fail("Entoli stopped this turn");
    }
    await _server.close(force: true);
  }
}
