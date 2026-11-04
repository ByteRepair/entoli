import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/permission_classifier.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

import "builtin_fakes.dart";

void main() {
  group("LlmClassifier", () {
    late FakeLlmClient client;

    LlmClassifier classifierOver(List<LlmChunk> reply) {
      client = FakeLlmClient([reply]);
      return LlmClassifier(client: client, model: "classifier-model");
    }

    test("the first word is the answer, anything else is ask", () async {
      const cases = {
        "allow": PermissionDecision.allow,
        "deny": PermissionDecision.deny,
        "ask": PermissionDecision.ask,
        "allow this command": PermissionDecision.allow,
        "Allow.": PermissionDecision.allow,
        "**Deny**": PermissionDecision.deny,
        "disallow": PermissionDecision.ask,
        "maybe": PermissionDecision.ask,
        "": PermissionDecision.ask,
      };
      for (final MapEntry(key: reply, value: decision) in cases.entries) {
        final c = classifierOver([saidOnly(reply)]);
        expect(
          await c.classify("bash", '{"command": "ls"}', workspace: "/tmp"),
          decision,
          reason: reply,
        );
      }
    });

    test("a failed request falls back to ask", () async {
      client = FakeLlmClient([]);
      client.failures[0] = const LlmException("timeout", retryable: false);
      final c = LlmClassifier(client: client, model: "classifier-model");
      final decision = await c.classify(
        "bash",
        '{"command": "ls"}',
        workspace: "/tmp",
      );
      expect(decision, PermissionDecision.ask);
    });

    test("bash shows the command and webfetch the URL, not the JSON", () async {
      var c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "echo hi"}', workspace: "/tmp");
      expect(client.sent.single.last.text, contains("echo hi"));
      expect(client.sent.single.last.text, isNot(contains('"command"')));

      c = classifierOver([saidOnly("allow")]);
      await c.classify(
        "webfetch",
        '{"url": "https://example.com"}',
        workspace: "/tmp",
      );
      expect(client.sent.single.last.text, contains("https://example.com"));
      expect(client.sent.single.last.text, isNot(contains('"url"')));
    });

    test("granted directories reach the prompt as writable", () async {
      var c = classifierOver([saidOnly("allow")]);
      await c.classify(
        "bash",
        '{"command": "ls"}',
        workspace: "/ws",
        alsoWritable: ["/proj", "/home/u/repo"],
      );
      expect(
        client.sent.single.last.text,
        contains("Also writable: /proj, /home/u/repo"),
      );

      c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "ls"}', workspace: "/ws");
      expect(client.sent.single.last.text, isNot(contains("Also writable")));
    });
  });
}
