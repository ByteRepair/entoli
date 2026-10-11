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

    test("the first word is the answer", () async {
      final allow = classifierOver([saidOnly("allow")]);
      expect(await allow.classify("bash", '{"command": "ls"}', workspace: "/tmp"),
          PermissionDecision.allow);

      // Deny refuses; ask is the escalation.
      final deny = classifierOver([saidOnly("deny")]);
      expect(await deny.classify("bash", '{"command": "rm -rf /"}', workspace: "/tmp"),
          PermissionDecision.deny);

      final ask = classifierOver([saidOnly("ask")]);
      expect(await ask.classify("bash", '{"command": "git push"}', workspace: "/tmp"),
          PermissionDecision.ask);
    });

    test("a reply with extra text still parses the first word", () async {
      final c = classifierOver([saidOnly("allow this command")]);
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.allow);
    });

    test("a reply that is not one of the words falls back to ask", () async {
      final strange = classifierOver([saidOnly("maybe")]);
      expect(await strange.classify("bash", '{"command": "ls"}', workspace: "/tmp"),
          PermissionDecision.ask);

      // Nothing said at all: the same fall-back.
      final empty = classifierOver([saidOnly("")]);
      expect(await empty.classify("bash", '{"command": "ls"}', workspace: "/tmp"),
          PermissionDecision.ask);
    });

    test("a failed request falls back to ask", () async {
      client = FakeLlmClient([]);
      client.failures[0] = const LlmException("timeout", retryable: false);
      final c = LlmClassifier(client: client, model: "classifier-model");
      final decision = await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      expect(decision, PermissionDecision.ask);
    });

    test("webfetch is classified with the URL in the prompt", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("webfetch", '{"url": "https://example.com"}', workspace: "/tmp");
      expect(client.sent.single.last.text, contains("https://example.com"));
    });

    test("bash shows the command plainly, not as JSON", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "echo hi"}', workspace: "/tmp");
      expect(client.sent.single.last.text, contains("echo hi"));
      expect(client.sent.single.last.text, isNot(contains('"command"')));
    });

    test("the system prompt has the rules, anchored on workspace writes", () async {
      final c = classifierOver([saidOnly("allow")]);
      await c.classify("bash", '{"command": "ls"}', workspace: "/tmp");
      final system = client.sent.single.first.text;
      expect(system, contains("allow"));
      expect(system, contains("deny"));
      expect(system, contains("ask"));
      // The rubric's key facts: in-workspace writes are what auto mode allows,
      // /tmp is a write past them (ask, not deny), and deny is reserved for
      // destruction rather than being a stronger ask.
      expect(system, contains("writes only inside the workspace"));
      expect(system, contains("output to /tmp is ask"));
      expect(system, contains("Deny is not a stronger ask"));
    });
  });
}
