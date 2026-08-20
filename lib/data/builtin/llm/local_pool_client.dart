import "../../../domain/app_settings.dart";
import "../../../domain/local_llm.dart";
import "llm_client.dart";
import "local_kv_cache.dart";
import "openai_client.dart";

/// How the pool is to be run, read fresh for every call.
///
/// Read rather than held for the reason `LocalShell` re-reads its environment:
/// the settings page edits these long after this client was built, and a change
/// should reach the next turn rather than the next launch.
typedef LocalPoolOptions = ({
  String? device,
  int? contextLength,
  int maxRunning,
  int? threads,
  int kvCacheChats,
});

/// The pool options the settings have. One mapper so the client that reaches a
/// model and the prefill that warms it read them the same way — the pool keys
/// and evicts slots on these, so a warm built from a different reading would be
/// evicted rather than reused. `kvCacheChats` collapses the "Default (10)" the
/// UI shows into the number the provider counts, so nothing else has to know
/// that null means ten.
LocalPoolOptions poolOptions(AppSettings settings) => (
      device: settings.localModelDevice,
      contextLength: settings.localModelContext,
      maxRunning: settings.maxLocalModels,
      threads: settings.localModelThreads,
      kvCacheChats:
          settings.localModelKvCacheChats ?? AppSettings.defaultKvCacheChats,
    );

extension LocalPoolCaching on LocalPoolOptions {
  /// Whether the KV cache is on, the one place null-means-ten and zero-means-off
  /// is read as a yes/no rather than spelled out at each site that gates on it.
  bool get kvCacheOn => kvCacheChats > 0;
}

/// The on-device provider, as one client over however many servers are running.
///
/// Every model on disk is one entry in one provider, but each is its own
/// process on a port of its own — so the model named in a request is what
/// decides where the request goes, and asking is also what loads it. That is
/// why this exists rather than the endpoint carrying a base URL: there is no
/// single address for "on-device", and a provider per model would put four
/// near-identical entries in every picker and break a chat's pinned model the
/// moment the catalog changed.
///
/// It replaced a client that only waited for one server to come up. Waiting is
/// still here — it is what [LocalLlm.serve] does — but it is now the tail of
/// starting rather than the whole job.
class LocalPoolClient implements LlmClient {
  LocalPoolClient(this._llm, this._options, {LocalKvCache? kvCache})
      : _kv = kvCache;

  final LocalLlm _llm;
  final LocalPoolOptions Function() _options;

  /// Where a turn's KV is saved and restored, or null where this build keeps
  /// none — every platform but Android. See [LocalKvCache].
  final LocalKvCache? _kv;

  /// One client per model, dropped when that model's server comes up again on
  /// a new port. The port is the whole signature here — everything else about
  /// how to reach a local server is fixed.
  final _clients = LlmClientCache();

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final options = _options();
    final at = await _serve(model, options);

    // Restore before, save after — content-addressed, so the whole of it is
    // this model's own and no chat id is anywhere in it. Best-effort by
    // construction: a miss or a build with no slot save/restore just pays the
    // prompt the way it did before. The keys are hashed once here and handed to
    // both halves rather than recomputed. See [LocalKvCache].
    final kv = options.kvCacheOn ? _kv : null;
    final namespace = kv == null
        ? null
        : kvNamespace(
            modelId: model,
            contextLength: at.contextLength,
            device: options.device,
          );
    final keys = kv == null ? const <String>[] : kvPrefixKeys(messages, tools);
    if (kv != null && keys.isNotEmpty) {
      await kv.warm(at, namespace: namespace!, keys: keys);
    }

    yield* _clientFor(model, at).stream(
      messages,
      model: model,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );

    if (kv != null && keys.isNotEmpty) {
      await kv.keep(
        at,
        namespace: namespace!,
        key: keys.first,
        count: options.kvCacheChats,
      );
    }
  }

  /// Answered from what is on disk rather than by asking a server, since asking
  /// would mean loading one — and this is what the model picker calls.
  @override
  Future<List<String>> listModels() async => _llm.provider?.models ?? const [];

  @override
  void close() => _clients.close();

  /// Why it will never answer, as an [LlmException] — otherwise the agent's
  /// error arm reports a bare exception and the reason the model would not
  /// load, which is the only thing worth reading, is not in it.
  Future<LocalEndpoint> _serve(String model, LocalPoolOptions options) async {
    try {
      return await _llm.serve(
        model,
        device: options.device,
        contextLength: options.contextLength,
        maxRunning: options.maxRunning,
        threads: options.threads,
        kvCache: options.kvCacheOn,
      );
    } on LocalLlmFailure catch (e) {
      throw LlmException(e.message);
    }
  }

  LlmClient _clientFor(String model, LocalEndpoint at) =>
      _clients.of(model, at.baseUrl, () => OpenAiClient(
            baseUrl: Uri.parse(at.baseUrl),
            apiKey: at.apiKey,
            // llama.cpp's own extension, and the only place it is asked for: it
            // is what turns a minute of prefill into something the chat can
            // draw. A hosted provider would reject the field, which is why it
            // rides on this client rather than on every request the app makes.
            returnProgress: true,
          ));
}
