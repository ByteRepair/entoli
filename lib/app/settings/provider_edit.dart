import "../../core/log.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart" show KeyCheck;

/// What saving a provider makes: the endpoint, and what becomes of its key —
/// the text to store, "" to remove the stored one, null to leave it — which
/// goes to the secret store rather than onto the config.
typedef ProviderDraft = ({LlmProviderConfig config, String? setKey});

/// A provider being added or edited, as its dialog holds it. A new one starts
/// from [preset], or from nothing for an endpoint typed in by hand; an edit
/// is read as the preset its entry is of. What is left empty falls back to
/// the preset's: its name, its base URL, its models.dev id.
class ProviderEdit {
  ProviderEdit(
    this.provider, {
    LlmProvider? preset,
    required this.id,
    required this.nameTaken,
    this.storedKey,
  }) : preset = provider == null ? preset : presetOf(provider),
       _api = provider?.api ?? preset?.config.api ?? LlmApi.openai,
       name = provider?.displayName ?? "",
       baseUrl = provider?.baseUrl ?? "",
       modelsEndpoint = provider?.modelsEndpoint ?? "",
       catalogId = provider?.catalogId ?? "",
       command = provider?.command ?? "",
       env = {...?provider?.env};

  /// The entry edited; null for a new one.
  final LlmProviderConfig? provider;

  /// The preset the entry is of. A CLI has none once it is saved: its entry
  /// is its program.
  final LlmProvider? preset;

  /// The id it is saved under: a new entry's is given before the dialog
  /// opens, since a program's account is kept in a folder named by it and
  /// can be signed in before Save.
  final String id;

  final bool Function(String name) nameTaken;

  /// The key kept for it now, where there is one.
  final String? storedKey;

  LlmApi _api;

  /// A preset's API is its own.
  LlmApi get api => preset?.config.api ?? _api;
  set api(LlmApi value) => _api = value;

  String name;
  String key = "";

  /// "Remove saved key" pressed. A key typed after it replaces rather than
  /// removes.
  bool removeKey = false;
  String baseUrl;
  String modelsEndpoint;
  String catalogId;
  String command;
  Map<String, String> env;

  bool get adding => provider == null;

  String get title => provider != null
      ? "Edit ${provider!.displayName}"
      : preset != null
      ? "Connect ${preset!.displayName}"
      : "Add provider";

  /// The preset's own name, which the plain words are about whatever the
  /// entry is called.
  String get service => preset?.displayName ?? "The provider";

  String get resolvedName {
    final typed = name.trim();
    return typed.isNotEmpty ? typed : preset?.displayName ?? "";
  }

  String get resolvedBaseUrl {
    final typed = baseUrl.trim();
    return typed.isNotEmpty ? typed : preset?.config.baseUrl ?? "";
  }

  String? get nameError {
    final name = resolvedName;
    return name.isNotEmpty && nameTaken(name)
        ? "Another provider is called $name"
        : null;
  }

  bool get canSave {
    final name = resolvedName;
    if (name.isEmpty || nameTaken(name)) return false;
    return api.isCli || resolvedBaseUrl.isNotEmpty;
  }

  ProviderDraft get draft {
    final base = provider ?? preset?.config;
    final name = resolvedName;
    if (api.isCli) {
      final command = this.command.trim();
      final cli = cliPresetOf(api).config;
      return (
        config: LlmProviderConfig(
          id: id,
          api: api,
          baseUrl: "",
          name: name,
          defaultModelId: base?.defaultModelId ?? cli.defaultModelId,
          defaultLightModelId:
              base?.defaultLightModelId ?? cli.defaultLightModelId,
          customModels: provider?.customModels ?? const [],
          command: command.isEmpty ? null : command,
          env: env,
        ),
        // A program holds its own sign-in; whatever was stored stays put.
        setKey: null,
      );
    }
    final key = this.key.trim();
    final modelsEndpoint = this.modelsEndpoint.trim();
    final catalogId = this.catalogId.trim();
    return (
      config: LlmProviderConfig(
        id: id,
        api: api,
        baseUrl: resolvedBaseUrl,
        name: name,
        catalogId: catalogId.isEmpty ? base?.catalogId : catalogId,
        apiKeyEnv: base?.apiKeyEnv,
        defaultModelId: base?.defaultModelId,
        defaultLightModelId: base?.defaultLightModelId,
        customModels: provider?.customModels ?? const [],
        modelsEndpoint: modelsEndpoint.isEmpty ? null : modelsEndpoint,
      ),
      // Over no stored key, clearing is the honest answer: a key saved since
      // the dialog opened is not resurrected by a save that typed nothing.
      setKey: key.isNotEmpty
          ? key
          : storedKey == null || removeKey
          ? ""
          : null,
    );
  }
}

/// Whether [draft]'s typed key is one its provider takes: false where it
/// refused it, null where there is no key to ask about or no answer came,
/// which is not a no.
Future<bool?> checkProviderKey(KeyCheck check, ProviderDraft draft) async {
  final key = draft.setKey;
  if (key == null || key.isEmpty) return null;
  try {
    return await check(draft.config, key);
  } catch (e) {
    logFailure("llm", "checking ${draft.config.id}'s key failed", e);
    return null;
  }
}

/// What a refused key is told.
String keyRefused(LlmProviderConfig config) =>
    "${presetOf(config)?.displayName ?? "The provider"} did not accept this "
    "key. Check it was copied whole.";

/// Whether [config] can answer, in plain words for a preset. An endpoint
/// typed in by hand is told apart by its address, which its owner knows.
String providerStatus(
  LlmProviderConfig config, {
  required String? storedKey,
  required String? Function(String name) env,
}) {
  final provider = providerOf(config);
  final hasKey =
      (storedKey != null && storedKey.isNotEmpty) ||
      config.resolveKeyWith(env) != null;
  final status = !provider.needsKey
      ? "On this computer"
      : hasKey
      ? "Connected"
      : "Needs a key";
  if (provider is CliProvider) return "${provider.command} · $status";
  return provider.terms == null ? "${config.baseUrl} · $status" : status;
}
