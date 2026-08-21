import "dart:async";
import "dart:io";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/llm/local_kv_cache.dart";
import "package:agent_chat/data/builtin/llm/local_prefill.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:flutter_test/flutter_test.dart";

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
  }) async =>
      kept.add(key);
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
    }) =>
        LocalPrefill(
          llm: llm,
          background: background,
          kvCache: kvCache,
          warmup: testWarmup(
            kvCachePrompts: kvCache == null ? 0 : 30,
            messages: messages,
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

    // The rest are against a real socket rather than the bogus port above: what
    // is worth pinning is whether the prompt was sent at all, and only a server
    // that would have answered can say it was not.
    group("against a server", () {
      late HttpServer server;
      late FakeLocalLlm llm;

      /// One request per warm-up that reached the model, and whether each was
      /// left open — a prefill still reading its prompt is one nothing has
      /// answered yet.
      var asked = 0;
      Completer<void>? held;

      setUp(() async {
        asked = 0;
        held = null;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(server.forEach((request) async {
          asked++;
          request.response.headers.contentType =
              ContentType("text", "event-stream");
          request.response.write(
              'data: {"prompt_progress":{"processed":1,"total":2}}\n\n');
          await request.response.flush();
          if (held != null) await held!.future;
          request.response
              .write('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n');
          await request.response.close();
        }));
        llm = FakeLocalLlm(baseUrl: "http://127.0.0.1:${server.port}/v1");
      });

      tearDown(() async {
        held?.complete();
        await server.close(force: true);
      });

      test("a body already on disk is restored rather than read again",
          () async {
        final kv = FakeLocalKvCache(hit: true);
        final background = FakeBackgroundWork();

        await make(llm, background, kvCache: kv)
            .warm("local-model");

        // The whole of the fix: a warm that hits is the warm-up, so the prompt
        // is not sent and nothing is written back over what was already there.
        expect(asked, 0);
        expect(kv.warmed.single, kvPrefixKeys(messages, const []));
        expect(kv.kept, isEmpty);
        expect(background.prefills.last, isNull);
      });

      test("a miss reads the prompt and saves the body", () async {
        final kv = FakeLocalKvCache();
        final background = FakeBackgroundWork();

        await make(llm, background, kvCache: kv)
            .warm("local-model");

        expect(asked, 1);
        expect(kv.kept, [kvPrefixKeys(messages, const []).last]);
      });

      test("the notification's Stop ends the warm-up", () async {
        held = Completer<void>();
        final background = FakeBackgroundWork();
        final prefill = make(llm, background);
        final warming = prefill.warm("local-model");
        await waitFor(() => asked == 1, what: "the warm-up request");
        expect(prefill.state.value, isNotNull);

        background.stop(BackgroundJob.prefill);
        // Ends where it is rather than when the held response finally
        // answers: the request is closed, not just marked superseded.
        await waitFor(() => prefill.state.value == null, what: "the warm-up stopping");
        await warming;

        expect(prefill.state.value, isNull);
        expect(background.prefills.last, isNull);
      });
    });
  });
}
