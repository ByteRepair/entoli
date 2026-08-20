import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";

void main() {
  group("LocalPrefill", () {
    LocalPrefill make(FakeLocalLlm llm, FakeBackgroundWork background) =>
        LocalPrefill(
          llm: llm,
          background: background,
          warmup: () => (
            options: (
              device: null,
              contextLength: null,
              maxRunning: 1,
              threads: null,
              kvCacheChats: 0,
            ),
            messages: const [
              LlmMessage(role: LlmRole.system, text: "system prompt body"),
              LlmMessage(role: LlmRole.user, text: "Hello"),
            ],
            tools: const [],
          ),
        );

    test("warming serves the model and brackets it with a notification",
        () async {
      final llm = FakeLocalLlm();
      final background = FakeBackgroundWork();

      await make(llm, background).warm("local-model");

      expect(llm.served.map((s) => s.modelId), ["local-model"]);
      // Shown while it runs and taken away when it is done, even though the
      // warm-up request itself cannot reach the fake's bogus endpoint — the
      // notice brackets the attempt, not its success.
      expect(background.prefills.first, isNotNull);
      expect(background.prefills.last, isNull);
    });

    test("a model that will not load is silent past the first notice", () async {
      final llm = FakeLocalLlm(ready: false);
      final background = FakeBackgroundWork();
      final prefill = make(llm, background);

      await prefill.warm("local-model");

      expect(llm.served, hasLength(1));
      expect(background.prefills.last, isNull);
      expect(prefill.state.value, isNull);
    });

    test("cancelling nothing does nothing", () async {
      final background = FakeBackgroundWork();
      await make(FakeLocalLlm(), background).cancel();
      expect(background.prefills, isEmpty);
    });
  });
}
