import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";

import "package:agent_chat/data/opencode/opencode_client.dart";

void main() {
  late List<Map<String, dynamic>> bodies;

  OpencodeClient client() {
    final mock = MockClient((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response("", 204);
    });
    return OpencodeClient(baseUrl: Uri.parse("http://127.0.0.1:1234"), httpClient: mock);
  }

  setUp(() => bodies = []);

  // The endpoint declares additionalProperties: false and types `model` as an
  // object, so a bare model string fails validation and the prompt is lost.
  test("promptAsync sends model as a providerID/modelID pair", () async {
    await client().promptAsync("ses_1", text: "hi", model: "qwen-2.5", provider: "ollama-cloud");

    expect(bodies.single["model"], {"providerID": "ollama-cloud", "modelID": "qwen-2.5"});
  });

  test("promptAsync omits model when the provider is unknown", () async {
    await client().promptAsync("ses_1", text: "hi", model: "qwen-2.5");

    expect(bodies.single.containsKey("model"), isFalse);
  });

  test("promptAsync omits model when nothing is selected", () async {
    await client().promptAsync("ses_1", text: "hi");

    expect(bodies.single.containsKey("model"), isFalse);
    expect(bodies.single["parts"], [
      {"type": "text", "text": "hi"}
    ]);
  });

  test("mentions travel as agent parts ahead of the text", () async {
    await client().promptAsync("ses_1", text: "@explore find it", agents: ["explore"]);

    expect(bodies.single["parts"], [
      {"type": "agent", "name": "explore"},
      {"type": "text", "text": "@explore find it"},
    ]);
  });

  // Unlike prompt_async, this endpoint types `model` as one string.
  test("runCommand sends model as one provider/model string", () async {
    await client().runCommand("ses_1",
        name: "review", arguments: "HEAD", model: "qwen-2.5", provider: "ollama-cloud");

    expect(bodies.single, {
      "command": "review",
      "arguments": "HEAD",
      "model": "ollama-cloud/qwen-2.5",
    });
  });

  test("runCommand still sends arguments when there are none", () async {
    await client().runCommand("ses_1", name: "init", arguments: "");

    expect(bodies.single, {"command": "init", "arguments": ""});
  });
}
