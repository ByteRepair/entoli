import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../controller.dart";

/// What a provider form makes: the endpoint, and what becomes of its key —
/// the text to store, "" to remove the stored one, null to leave it — which
/// goes to the secret store rather than onto the config.
typedef ProviderDraft = ({LlmProviderConfig config, String? setKey});

/// A provider added or edited, asking what the Flutter app's dialog asks: a
/// preset's plain words and its access key, and under Advanced the whole
/// entry in the endpoint's own terms — the API, then a base URL, a key, a
/// models endpoint and a catalog id, or a program and what it runs under.
class ProviderForm implements SettingForm<ProviderDraft> {
  ProviderForm(
    this.provider, {
    required this.nameTaken,
    required this.storedKey,
    this.encrypted = true,
  });

  final LlmProviderConfig? provider;
  final bool Function(String name) nameTaken;

  /// The key kept for it now, where there is one.
  final String? storedKey;

  /// Whether keys go to the OS keyring rather than the app's own store.
  final bool encrypted;

  static final _presets = [
    for (final p in llmProviderPresets) p,
    for (final p in cliProviderPresets)
      if (p.supported) p,
  ];

  /// "" is an entry typed in by hand.
  static String _keyOf(LlmProviderConfig config) =>
      presetOf(config)?.displayName ?? "";

  @override
  String get title =>
      provider == null ? "Add provider" : "Edit ${provider!.displayName}";

  @override
  Map<String, String> get initial => {
    "preset": provider == null ? "" : _keyOf(provider!),
    "name": provider?.displayName ?? "",
    "key": "",
    "keep": storedKey == null ? "" : "keep",
    "api": (provider?.api ?? LlmApi.openai).name,
    "baseUrl": provider?.baseUrl ?? "",
    "modelsEndpoint": provider?.modelsEndpoint ?? "",
    "catalogId": provider?.catalogId ?? "",
    "command": provider?.command ?? "",
    "env": [
      for (final MapEntry(:key, :value) in (provider?.env ?? const {}).entries)
        "$key=$value",
    ].join("\n"),
  };

  /// The preset the entry starts from, picked or edited.
  LlmProvider? _preset(Map<String, String> a) {
    final name = a["preset"]!;
    if (name.isEmpty) return null;
    return _presets.where((p) => p.displayName == name).firstOrNull;
  }

  LlmApi _api(Map<String, String> a) =>
      _preset(a)?.config.api ??
      LlmApi.values.asNameMap()[a["api"]] ??
      LlmApi.openai;

  String _name(Map<String, String> a) {
    final typed = a["name"]!.trim();
    return typed.isNotEmpty ? typed : _preset(a)?.displayName ?? "";
  }

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final preset = _preset(a);
    final api = _api(a);
    final terms = preset?.terms;
    final keyless = preset != null && !preset.needsKey;
    final service = preset?.displayName ?? "The provider";
    final name = _name(a);
    return [
      if (provider == null)
        FormChoice("preset", label: "Provider", [
          const FormOption("", "Custom endpoint"),
          for (final p in _presets) FormOption(p.displayName, p.displayName),
        ]),
      FormText(
        "name",
        "Name",
        hint: preset?.displayName,
        helper: "What the model list calls it",
        error: name.isNotEmpty && nameTaken(name)
            ? "Another provider is called $name"
            : null,
        focused: provider == null,
      ),
      if (terms != null && !api.isCli) ...[
        FormNote(
          keyless
              ? "$service runs on this computer, so there is nothing to type. "
                    "Start $service before you chat."
              : "Entoli needs an access key from your $service account to "
                    "talk to it. Create one on $service's website"
                    "${terms.keyUrl == null ? "" : " (${terms.keyUrl})"}, copy "
                    "it, and paste it below.",
        ),
        if (!keyless)
          FormText(
            "key",
            "Access key",
            helper: storedKey != null
                ? "Leave empty to keep the key you saved"
                : "Kept private on this device",
          ),
        if (terms.policy case final policy?)
          FormNote("$service's privacy policy: $policy"),
        const FormQuestion("Advanced"),
      ],
      if (preset == null)
        FormChoice("api", label: "API", [
          const FormOption("openai", "OpenAI-compatible"),
          const FormOption("anthropic", "Anthropic"),
          for (final cli in cliProviderPresets)
            if (cli.supported || provider?.api == cli.config.api)
              FormOption(cli.config.api.name, cli.config.displayName),
        ]),
      if (api.isCli) ...[
        FormNote(cliPresetOf(api).about),
        FormText(
          "command",
          "Executable",
          hint: cliPresetOf(api).defaultCommand,
          helper: "Empty runs ${cliPresetOf(api).defaultCommand} from PATH",
        ),
        const FormList(
          "env",
          "Environment",
          hint: "NAME=value",
          helper: "What the program runs with, over the app's own. One a line.",
        ),
      ] else ...[
        FormText(
          "baseUrl",
          "Base URL",
          hint: preset?.config.baseUrl,
          helper: "The versioned root, e.g. https://api.openai.com/v1",
        ),
        if (terms == null || keyless)
          FormText(
            "key",
            "API key",
            helper: storedKey != null
                ? "Leave empty to keep the stored key"
                : provider?.apiKeyEnv == null
                ? "Stored in the ${encrypted ? "OS keyring" : "app secret store"}"
                : "Leave empty to read \$${provider!.apiKeyEnv} from the "
                      "environment",
          ),
        if (storedKey != null)
          const FormChoice("keep", label: "Saved key", [
            FormOption("keep", "Keep the saved key"),
            FormOption("", "Remove the saved key"),
          ]),
        const FormText(
          "modelsEndpoint",
          "Models endpoint",
          helper:
              "Empty lists the models models.dev has for it. Filled, lists "
              "this endpoint's instead, e.g. http://localhost:11434/v1/models.",
        ),
        const FormText(
          "catalogId",
          "Provider ID",
          helper:
              "Its id on models.dev, which lists its models when the models "
              "endpoint is empty, e.g. google. Empty matches it by base URL.",
        ),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) {
    final name = _name(a);
    if (name.isEmpty || nameTaken(name)) return "";
    if (!_api(a).isCli && _baseUrl(a).isEmpty) return "";
    return null;
  }

  String _baseUrl(Map<String, String> a) {
    final typed = a["baseUrl"]!.trim();
    return typed.isNotEmpty ? typed : _preset(a)?.config.baseUrl ?? "";
  }

  @override
  ProviderDraft build(Map<String, String> a) {
    final preset = _preset(a)?.config;
    final base = provider ?? preset;
    final api = _api(a);
    final name = _name(a);
    if (api.isCli) {
      final command = a["command"]!.trim();
      final cli = cliPresetOf(api).config;
      return (
        config: LlmProviderConfig(
          id: provider?.id ?? "",
          api: api,
          baseUrl: "",
          name: name,
          defaultModelId: base?.defaultModelId ?? cli.defaultModelId,
          defaultLightModelId:
              base?.defaultLightModelId ?? cli.defaultLightModelId,
          customModels: provider?.customModels ?? const [],
          command: command.isEmpty ? null : command,
          env: {
            for (final line in a["env"]!.split("\n"))
              if (line.indexOf("=") case final at when at > 0)
                line.substring(0, at).trim(): line.substring(at + 1),
          },
        ),
        // A program holds its own sign-in; whatever was stored stays put.
        setKey: null,
      );
    }
    final key = a["key"]!.trim();
    final modelsEndpoint = a["modelsEndpoint"]!.trim();
    final catalogId = a["catalogId"]!.trim();
    return (
      config: LlmProviderConfig(
        id: provider?.id ?? "",
        api: api,
        baseUrl: _baseUrl(a),
        name: name,
        catalogId: catalogId.isEmpty ? base?.catalogId : catalogId,
        apiKeyEnv: base?.apiKeyEnv,
        defaultModelId: base?.defaultModelId,
        defaultLightModelId: base?.defaultLightModelId,
        customModels: provider?.customModels ?? const [],
        modelsEndpoint: modelsEndpoint.isEmpty ? null : modelsEndpoint,
      ),
      setKey: key.isNotEmpty
          ? key
          : storedKey == null
          ? ""
          : a["keep"] == "keep"
          ? null
          : "",
    );
  }
}
