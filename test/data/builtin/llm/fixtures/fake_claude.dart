// A stand-in for `claude -p` in stream-json mode, for cli_provider_test.dart.
// It speaks the same lines on stdin and stdout and reaches the tools over the
// MCP config it is handed, which is the whole of what the session relies on.
//
// A message saying "use echo" gets a reply calling `echo`, then — once the
// held call is answered — a reply quoting what it said. Anything else gets
// "hello again". Its argv goes to $FAKE_CLAUDE_LOG.
import "dart:convert";
import "dart:io";

Future<void> main(List<String> args) async {
  final log = Platform.environment["FAKE_CLAUDE_LOG"];
  if (log != null) File(log).writeAsStringSync(jsonEncode(args));
  final config =
      jsonDecode(
            File(args[args.indexOf("--mcp-config") + 1]).readAsStringSync(),
          )
          as Map;
  final server = (config["mcpServers"] as Map)["entoli"] as Map?;

  void out(Map<String, dynamic> line) => stdout.writeln(jsonEncode(line));
  void event(Map<String, dynamic> e) =>
      out({"type": "stream_event", "event": e, "parent_tool_use_id": null});
  void message(List<Map<String, dynamic>> blocks, String stop) {
    event({
      "type": "message_start",
      "message": {
        "usage": {"input_tokens": 10, "output_tokens": 1},
      },
    });
    for (final (i, block) in blocks.indexed) {
      if (block["type"] == "text") {
        event({
          "type": "content_block_start",
          "index": i,
          "content_block": {"type": "text", "text": ""},
        });
        event({
          "type": "content_block_delta",
          "index": i,
          "delta": {"type": "text_delta", "text": block["text"]},
        });
      } else {
        event({
          "type": "content_block_start",
          "index": i,
          "content_block": {
            "type": "tool_use",
            "id": block["id"],
            "name": block["name"],
          },
        });
        event({
          "type": "content_block_delta",
          "index": i,
          "delta": {
            "type": "input_json_delta",
            "partial_json": jsonEncode(block["input"]),
          },
        });
      }
      event({"type": "content_block_stop", "index": i});
    }
    event({
      "type": "message_delta",
      "delta": {"stop_reason": stop},
      "usage": {"output_tokens": 5},
    });
    event({"type": "message_stop"});
  }

  Future<Map> rpc(String method, Map params) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(server!["url"] as String));
      (server["headers"] as Map).forEach(
        (k, v) => request.headers.set(k as String, v as String),
      );
      request.write(
        jsonEncode({
          "jsonrpc": "2.0",
          "id": 1,
          "method": method,
          "params": params,
        }),
      );
      final response = await request.close();
      return jsonDecode(await utf8.decodeStream(response)) as Map;
    } finally {
      client.close();
    }
  }

  out({
    "type": "system",
    "subtype": "init",
    "mcp_servers": [
      if (server != null) {"name": "entoli", "status": "connected"},
    ],
  });
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final content =
        ((jsonDecode(line) as Map)["message"] as Map)["content"] as List;
    final text = content
        .whereType<Map>()
        .where((b) => b["type"] == "text")
        .map((b) => b["text"])
        .join();
    if (text.contains("use echo")) {
      message([
        {"type": "text", "text": "calling"},
        {
          "type": "tool_use",
          "id": "toolu_1",
          "name": "mcp__entoli__echo",
          "input": {"x": 1},
        },
      ], "tool_use");
      await rpc("initialize", {"protocolVersion": "2025-06-18"});
      final listed = await rpc("tools/list", {});
      final names = [
        for (final t in (listed["result"] as Map)["tools"] as List) t["name"],
      ];
      final called = await rpc("tools/call", {
        "name": "echo",
        "arguments": {"x": 1},
      });
      final said =
          (((called["result"] as Map)["content"] as List).first as Map)["text"];
      message([
        {"type": "text", "text": "tools $names; echo said $said"},
      ], "end_turn");
    } else {
      message([
        {"type": "text", "text": "hello again"},
      ], "end_turn");
    }
    out({"type": "result", "subtype": "success", "is_error": false});
  }
}
