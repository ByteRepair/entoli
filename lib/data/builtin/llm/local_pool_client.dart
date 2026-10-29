import "package:http/http.dart" as http;

import "../../../domain/app_settings.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model.dart" show localProviderId;
import "../../../domain/model_capability.dart";
import "../../../domain/model_registry.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model.dart";
import "hosted_models.dart";
import "llm_client.dart";
import "local_kv_cache.dart";
import "openai_client.dart";
import "providers/provider.dart";

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
  int kvCachePrompts,
});

/// The pool options the settings have. One mapper so the client that reaches a
/// model and the prefill that warms it read them the same way — the pool keys
/// and evicts slots on these, so a warm built from a different reading would be
/// evicted rather than reused. `kvCachePrompts` collapses the "Default (10)" the
/// UI shows into the number the provider counts, so nothing else has to know
/// that null means ten.
LocalPoolOptions poolOptions(AppSettings settings) => (
      device: settings.localModelDevice,
      contextLength: settings.localModelContext,
      maxRunning: settings.maxLocalModels,
      threads: settings.localModelThreads,
      kvCachePrompts:
          settings.localModelKvCachePrompts ?? AppSettings.defaultKvCachePrompts,
    );

extension LocalPoolCaching on LocalPoolOptions {
  /// Whether the KV cache is on, the one place null-means-ten and zero-means-off
  /// is read as a yes/no rather than spelled out at each site that gates on it.
  bool get kvCacheOn => kvCachePrompts > 0;
}

/// Every model on this device as one provider, an entry the user never
/// configures: the downloaded text models, run by the pool below, and the voice
/// models, run by the platform's [Voice]. No key reaches it.
///
/// Always there, with nothing in it until something is downloaded — an empty
/// provider is in no picker, so nothing has to keep it out of one.
class OnDeviceProvider extends LlmProvider with KeyFree {
  const OnDeviceProvider(this._llm, this._options,
      {LocalKvCache? kvCache, required this.voices})
      : _kv = kvCache,
        super(onDeviceConfig);

  final LocalLlm _llm;
  final LocalPoolOptions Function() _options;
  final LocalKvCache? _kv;

  /// The voice models usable here: downloaded, or a system engine the device
  /// has. Read when asked, since a download lands while this is held.
  final Set<String> Function() voices;

  @override
  LlmClient client(String? apiKey) => LocalPoolClient(_llm, _options, kvCache: _kv);

  /// The text models alone, which are what a chat lists. Answered from what is
  /// on disk rather than by asking a server, since asking would mean loading
  /// one.
  @override
  Future<List<String>> listModels(String? apiKey, {http.Client? httpClient}) async =>
      _llm.installed;

  /// What it has is on the disk, not in models.dev, so [info] says nothing and
  /// an id it has not got is nothing at all.
  @override
  List<Model> serve(String id, ModelInfo? info, ModelHost host) {
    final ref = (providerId: localProviderId, modelId: id);
    final voice = voices().contains(id) ? voiceModelById(id) : null;
    return [
      if (_llm.installed.contains(id))
        HostedChatModel(ref, ModelInfo(id: id, toolCall: true)),
      if (voice is RecognitionModel) OnDeviceTranscriptionModel(ref, voice),
      if (voice is SpeechModel) OnDeviceSynthesisModel(ref, voice),
    ];
  }

  @override
  Iterable<Model> offered(ModelCatalog catalog, ModelHost host) =>
      [for (final id in {..._llm.installed, ...voices()}) ...serve(id, null, host)];
}

/// A voice model on the device, as the platform's [Voice] runs it.
class OnDeviceTranscriptionModel implements TranscriptionModel {
  const OnDeviceTranscriptionModel(this.ref, this.model);

  @override
  final ModelRef ref;
  final RecognitionModel model;

  @override
  ModelInfo get info =>
      ModelInfo(id: model.id, name: model.name, talks: false, transcribes: true);

  @override
  Hearing get hearing => HearOnDevice(model);

  @override
  bool get systemEngine => model.isNative;
}

class OnDeviceSynthesisModel implements SynthesisModel {
  const OnDeviceSynthesisModel(this.ref, this.model);

  @override
  final ModelRef ref;
  final SpeechModel model;

  @override
  ModelInfo get info => ModelInfo(id: model.id, name: model.name, talks: false, speaks: true);

  /// A hosted provider's voice means nothing here: which of the model's
  /// speakers reads is its own setting.
  @override
  Speaking speaking({String? voice}) => SpeakOnDevice(model);

  @override
  bool get systemEngine => model.isNative;

  @override
  bool get namesVoices => false;

  @override
  int get speakers => model.isNative ? 0 : model.speakers;
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
  /// none — every platform with no bundled server. See [LocalKvCache].
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
    final kv = kvLookup(
      _kv,
      on: options.kvCacheOn,
      modelId: model,
      at: at,
      device: options.device,
      messages: messages,
      tools: tools,
    );
    if (kv != null) {
      await kv.cache.warm(at, namespace: kv.namespace, keys: kv.keys);
    }

    yield* _clientFor(model, at).stream(
      messages,
      model: model,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );

    if (kv != null) {
      await kv.cache.keep(
        at,
        namespace: kv.namespace,
        key: kv.keys.first,
        count: options.kvCachePrompts,
      );
    }
  }

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
