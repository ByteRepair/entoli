import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/local/local_instance.dart";
import "package:agent_chat/data/local/prompt_cache.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";

void main() {
  const tools = [
    LlmTool(
      name: "bash",
      description: "run a command",
      schema: {"type": "object"},
    ),
  ];
  LlmMessage sys(String t) => LlmMessage(role: LlmRole.system, text: t);
  LlmMessage user(String t) => LlmMessage(role: LlmRole.user, text: t);

  group("stateNamespace", () {
    LocalInstance instance(String id, {int context = 8192, String? device}) =>
        FakeLocalRuntime().create(
          DownloadedModel(
            id: id,
            name: id,
            file: "/models/$id",
            bytes: 0,
            quantisation: "Q4_0",
            contextLength: context,
            kvBytesPerToken: 0,
          ),
          LocalLoad(contextLength: context, device: device),
          onChange: () {},
        );

    test("is a faithful function of what the state is tied to", () {
      // The same binding answers the same string: no hidden entropy to make
      // two files land apart for no reason.
      expect(
        instance("qwen", device: "HTP0").stateNamespace,
        instance("qwen", device: "HTP0").stateNamespace,
      );

      final base = instance("qwen").stateNamespace;
      // A different model, context, or device makes another namespace — which
      // is the whole of the invalidation: the file lands where nothing looks.
      expect(instance("llama").stateNamespace, isNot(base));
      expect(instance("qwen", context: 4096).stateNamespace, isNot(base));
      expect(instance("qwen", device: "HTP0").stateNamespace, isNot(base));
    });
  });

  group("promptPrefixKeys", () {
    test("is one key per message, longest prefix first", () {
      final keys = promptPrefixKeys([sys("s"), user("a"), user("b")], tools);
      expect(keys, hasLength(3));
      expect(keys.toSet(), hasLength(3));
    });

    test("a longer conversation extends the same prefixes", () {
      // Appending a turn leaves every earlier boundary's key untouched — the
      // property that lets a reopened chat restore the longest match.
      final two = promptPrefixKeys([sys("s"), user("a")], tools);
      final three = promptPrefixKeys([sys("s"), user("a"), user("b")], tools);
      expect(three.sublist(1), two);
    });

    test("chats sharing a system prompt share their body key", () {
      // The shortest key — the system+tools body — is what the prefill warms and
      // every chat reuses, so two chats with the same head must agree on it.
      final a = promptPrefixKeys([sys("same"), user("hello")], tools);
      final b = promptPrefixKeys([sys("same"), user("different")], tools);
      expect(a.last, b.last);
      expect(a.first, isNot(b.first));
    });

    test("a different tool set is a different body", () {
      final withBash = promptPrefixKeys([sys("s"), user("a")], tools);
      final withNone = promptPrefixKeys([sys("s"), user("a")], const []);
      expect(withBash.last, isNot(withNone.last));
    });
  });

  group("promptEvictions", () {
    PromptFile file(String name, int day, {int size = 100}) =>
        (name: name, size: size, modified: DateTime(2026, 1, day));

    test("keeps the newest count of the namespace and drops the rest", () {
      final files = [
        file("ns.a.bin", 1),
        file("ns.b.bin", 2),
        file("ns.c.bin", 3),
      ];
      final doomed = promptEvictions(
        files,
        namespace: "ns",
        count: 2,
        budgetBytes: 1 << 30,
      );
      expect(doomed, {"ns.a.bin"});
    });

    test("another namespace is left alone by the count", () {
      final files = [
        file("ns.a.bin", 1),
        file("ns.b.bin", 2),
        file("other.x.bin", 1),
      ];
      final doomed = promptEvictions(
        files,
        namespace: "ns",
        count: 1,
        budgetBytes: 1 << 30,
      );
      // Only this namespace's older dump goes; the other model's stays.
      expect(doomed, {"ns.a.bin"});
    });

    test("the budget reaps the globally oldest, whatever namespace", () {
      final files = [
        file("ns.a.bin", 5, size: 100),
        file("other.old.bin", 1, size: 100),
        file("other.new.bin", 4, size: 100),
      ];
      // Room for two of the three: the single oldest survivor is dropped, and it
      // belongs to the abandoned namespace the count never looks at.
      final doomed = promptEvictions(
        files,
        namespace: "ns",
        count: 10,
        budgetBytes: 200,
      );
      expect(doomed, {"other.old.bin"});
    });
  });
}
