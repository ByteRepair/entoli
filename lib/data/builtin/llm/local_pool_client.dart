import "../../../domain/local_llm.dart";
import "llm_client.dart";
import "openai_client.dart";

/// How the pool is to be run, read fresh for every call.
///
/// Read rather than held for the reason `LocalShell` re-reads its environment:
/// the settings page edits these long after this client was built, and a change
/// should reach the next turn rather than the next launch.
typedef LocalPoolOptions = ({String? device, int? contextLength, int maxRunning});

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
  LocalPoolClient(this._llm, this._options);

  final LocalLlm _llm;
  final LocalPoolOptions Function() _options;

  /// One HTTP client per model, dropped when that model's server is started
  /// again on a new port — the same signature check `LlmRegistry` makes, and
  /// what keeps this from growing an entry per launch.
  final _clients = <String, ({String baseUrl, OpenAiClient client})>{};

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final at = await _serve(model);
    yield* _clientFor(model, at).stream(
      messages,
      model: model,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );
  }

  /// Answered from what is on disk rather than by asking a server, since asking
  /// would mean loading one — and this is what the model picker calls.
  @override
  Future<List<String>> listModels() async => _llm.provider?.models ?? const [];

  @override
  void close() {
    for (final entry in _clients.values) {
      entry.client.close();
    }
    _clients.clear();
  }

  /// Why it will never answer, as an [LlmException] — otherwise the agent's
  /// error arm reports a bare exception and the reason the model would not
  /// load, which is the only thing worth reading, is not in it.
  Future<LocalEndpoint> _serve(String model) async {
    final options = _options();
    try {
      return await _llm.serve(
        model,
        device: options.device,
        contextLength: options.contextLength,
        maxRunning: options.maxRunning,
      );
    } on LocalLlmFailure catch (e) {
      throw LlmException(e.message);
    }
  }

  OpenAiClient _clientFor(String model, LocalEndpoint at) {
    final cached = _clients[model];
    if (cached != null && cached.baseUrl == at.baseUrl) return cached.client;
    cached?.client.close();
    final client = OpenAiClient(
      baseUrl: Uri.parse(at.baseUrl),
      apiKey: at.apiKey,
      // llama.cpp's own extension, and the only place it is asked for: it is
      // what turns a minute of prefill into something the chat can draw. A
      // hosted provider would reject the field, which is why it rides on this
      // client rather than on every request the app makes.
      returnProgress: true,
    );
    _clients[model] = (baseUrl: at.baseUrl, client: client);
    return client;
  }
}
