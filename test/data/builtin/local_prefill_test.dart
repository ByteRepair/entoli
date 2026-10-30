import "dart:async";
import "dart:convert";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/local_kv_cache.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;

import "../fake_network.dart";
import "../../fakes.dart";
import "../../harness.dart";

/// [LocalKvCache] with nothing on a disk: [hit] is whether a dump for this body
/// was already there, which is the whole of what decides a warm-up's shape.
class FakeLocalKvCache implements LocalKvCache {
  FakeLocalKvCache({this.hit = false});

  final bool hit;
  final List<List<String>> warmed = [];
  final List<String> kept = [];

  @override
  Future<bool> warm(
    LocalEndpoint at, {
    required String namespace,
    required List<String> keys,
  }) async {
    warmed.add(keys);
    return hit;
  }

  @override
  Future<void> keep(
    LocalEndpoint at, {
    required String namespace,
    required String key,
    required int count,
  }) async => kept.add(key);
}

void main() {
  const messages = [
    LlmMessage(role: LlmRole.system, text: "system prompt body"),
    LlmMessage(role: LlmRole.user, text: "Hello"),
  ];

  group("LocalPrefill", () {
    // The cache and the count that turns it on are one knob: a cache passed
    // with the count left at zero is a cache nothing reaches.
    LocalPrefill make(
      FakeLocalLlm llm,
      FakeBackgroundWork background, {
      LocalKvCache? kvCache,
      http.Client? server,
    }) => LocalPrefill(
      llm: llm,
      background: background,
      kvCache: kvCache,
      // Nothing answers unless a test says so, which is what the fake
      // `LocalLlm`'s own endpoint amounts to.
      httpClient: server ?? FakeNetwork(const {}),
      warmup: testWarmup(
        kvCachePrompts: kvCache == null ? 0 : 30,
        messages: messages,
      ),
    );

    test(
      "warming serves the model and brackets it with a notification",
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
      },
    );

    test(
      "a model that will not load is silent past the first notice",
      () async {
        final llm = FakeLocalLlm(ready: false);
        final background = FakeBackgroundWork();
        final prefill = make(llm, background);

        await prefill.warm("local-model");

        expect(llm.served, hasLength(1));
        expect(background.prefills.last, isNull);
        expect(prefill.state.value, isNull);
      },
    );

    test("cancelling nothing does nothing", () async {
      final background = FakeBackgroundWork();
      await make(FakeLocalLlm(), background).cancel();
      expect(background.prefills, isEmpty);
    });

    // The rest are against a server that answers, rather than the endpoint
    // above that does not: what is worth pinning is whether the prompt was
    // sent at all, and only something that would have answered can say it was
    // not.
    group("against a server", () {
      late FakeNetwork server;
      late FakeLocalLlm llm;

      setUp(() {
        server = FakeNetwork(
          {
            "/v1/chat/completions": [
              utf8.encode(
                'data: {"prompt_progress":{"processed":1,"total":2}}\n\n',
              ),
              utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'),
            ],
          },
          headers: const {"content-type": "text/event-stream"},
        );
        llm = FakeLocalLlm(baseUrl: "${FakeNetwork.host}/v1");
      });

      tearDown(() => server.hold?.complete());

      test("the cache is the warm-up's first consult", () async {
        final background = FakeBackgroundWork();
        // Hit: a warm that hits is the warm-up, so the prompt is not sent and
        // nothing is written back over what was already there.
        final kv = FakeLocalKvCache(hit: true);
        await make(
          llm,
          background,
          kvCache: kv,
          server: server,
        ).warm("local-model");

        expect(server.asked, 0);
        expect(kv.warmed.single, kvPrefixKeys(messages, const []));
        expect(kv.kept, isEmpty);
        expect(background.prefills.last, isNull);

        // A miss reads the prompt and saves the body.
        final miss = FakeLocalKvCache();
        await make(
          llm,
          background,
          kvCache: miss,
          server: server,
        ).warm("local-model");

        expect(server.asked, 1);
        expect(miss.kept, [kvPrefixKeys(messages, const []).last]);
      });

      test("the notification's Stop ends the warm-up", () async {
        server.hold = Completer<void>();
        final background = FakeBackgroundWork();
        final prefill = make(llm, background, server: server);
        final warming = prefill.warm("local-model");
        await waitFor(() => server.asked == 1, what: "the warm-up request");
        expect(prefill.state.value, isNotNull);

        background.stop(BackgroundJob.prefill);
        // Ends where it is rather than when the held response finally
        // answers: the request is closed, not just marked superseded.
        await waitFor(
          () => prefill.state.value == null,
          what: "the warm-up stopping",
        );
        await warming;

        expect(prefill.state.value, isNull);
        expect(background.prefills.last, isNull);
      });
    });
  });
}
