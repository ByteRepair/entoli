import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../controller.dart";
import "../spec.dart";

/// What a provider form makes: the endpoint, and what becomes of its key —
/// the text to store, "" to remove the stored one, null to leave it — which
/// goes to the secret store rather than onto the config.
typedef ProviderDraft = ({LlmProviderConfig config, String? setKey});

/// The answer a new entry's preset holds until one is picked: the form is
/// then the list of presets and nothing else.
const _unpicked = "?";

/// A provider added or edited. A new one starts on the presets, each saying
/// what it does with the prompts it is sent, a free tier paid for in privacy
/// agreed to before anything else is asked. A preset then asks in plain words
/// for its access key, with where to make one and its privacy policy, and
/// folds the endpoint's own terms under Advanced; an endpoint typed in by
/// hand is those terms alone — the API, then a base URL, a key, a models
/// endpoint and a catalog id, or a program, its sign-in and what it runs
/// under.
class ProviderForm extends SettingForm<ProviderDraft> {
  ProviderForm(
    this.provider, {
    required this.nameTaken,
    required this.storedKey,
    required this.newId,
    this.preset,
    this.encrypted = true,
    this.forget,
  });

  final LlmProviderConfig? provider;

  /// The preset a new entry starts from where it was chosen before the form
  /// opened: a service connected by name.
  final LlmProvider? preset;

  final bool Function(String name) nameTaken;

  /// The key kept for it now, where there is one.
  final String? storedKey;

  /// Whether keys go to the OS keyring rather than the app's own store.
  final bool encrypted;

  /// The id a new entry is given before it is saved: a program's account is
  /// kept in a folder named by it, and can be signed in before Save.
  final String newId;

  /// Takes away what was made under a new entry's id — a program signed in —
  /// where the form is left unsaved.
  final Future<void> Function(String id)? forget;

  /// Asked each time: whether a program can run here is the platform's
  /// answer of the moment.
  static List<LlmProvider> get _presets => [
    for (final p in llmProviderPresets) p,
    for (final p in cliProviderPresets)
      if (p.supported) p,
  ];

  /// "" is an entry typed in by hand.
  static String _keyOf(LlmProviderConfig config) =>
      presetOf(config)?.displayName ?? "";

  @override
  String get title => provider != null
      ? "Edit ${provider!.displayName}"
      : preset != null
      ? "Connect ${preset!.displayName}"
      : "Add provider";

  @override
  Future<void> dismissed(Map<String, String> answers) async {
    if (provider == null) await forget?.call(answers["id"]!);
  }

  @override
  Map<String, String> get initial => {
    "id": provider?.id ?? newId,
    "preset": provider != null
        ? _keyOf(provider!)
        : preset?.displayName ?? _unpicked,
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
    "advanced": "",
  };

  /// The preset the entry starts from, picked or edited.
  LlmProvider? _preset(Map<String, String> a) {
    final name = a["preset"]!;
    if (name.isEmpty || name == _unpicked) return null;
    if (preset?.displayName == name) return preset;
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

  static String _consent(LlmProvider preset) => "consent:${preset.displayName}";

  /// Agreeing to a free tier's cost is wanted before anything else.
  static bool _owed(LlmProvider? preset, Map<String, String> a) =>
      preset?.terms?.freeTier != null && a[_consent(preset!)] != "yes";

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    if (a["preset"] == _unpicked) return [_picker(cards: true)];
    final preset = _preset(a);
    final terms = preset?.terms;
    final service = preset?.displayName ?? "The provider";
    return [
      if (provider == null && this.preset == null) _picker(cards: false),
      if (_owed(preset, a))
        FormConsent(
          _consent(preset!),
          title: "$service's free tier is not private",
          message: terms!.freeTier!,
          accept: "I understand, add it",
          link: terms.policy == null
              ? null
              : ("Read their terms", Uri.parse(terms.policy!)),
        )
      else ...[
        _nameField(a, preset),
        if (terms != null && !_api(a).isCli) ...[
          ..._plain(a, preset!, terms),
          const FormFold("advanced", "Advanced"),
          if (a["advanced"] == "open") ..._technical(a, preset),
        ] else
          ..._technical(a, preset),
      ],
    ];
  }

  /// Every preset to start from, with what each does with the prompts:
  /// the paid, the free at a cost to privacy, what runs on this machine, and
  /// an endpoint typed in by hand. One already configured is offered again,
  /// for a second account.
  FormChoice _picker({required bool cards}) {
    bool free(LlmProvider p) => p.terms?.freeTier != null;
    bool local(LlmProvider p) => p.terms?.prompts == PromptUse.local;
    String group(LlmProvider p) => p.config.api.isCli || local(p)
        ? "On this machine"
        : free(p)
        ? "Free, at a cost to privacy"
        : "Paid";
    final groups = ["Paid", "Free, at a cost to privacy", "On this machine"];
    final presets = [..._presets]
      ..sort((a, b) => groups.indexOf(group(a)) - groups.indexOf(group(b)));
    return FormChoice("preset", label: "Provider", cards: cards, [
      for (final p in presets)
        FormOption(
          p.displayName,
          p.displayName,
          group: group(p),
          help: switch (p) {
            CliProvider(:final about) => about,
            _ => p.terms?.blurb,
          },
          glyph: p.config.api.isCli
              ? SettingGlyph.terminal
              : local(p)
              ? SettingGlyph.computer
              : SettingGlyph.cloud,
          tags: [
            if (p case CliProvider(:final account)) FormTag(account),
            if (free(p)) const FormTag("Free", tone: NoticeTone.warning),
            if (p.terms?.prompts case final use?) _promptsTag(use),
            if (p.imageModel != null) const FormTag("Images"),
          ],
        ),
      const FormOption(
        "",
        "Custom…",
        help: "Any OpenAI- or Anthropic-compatible endpoint, by URL.",
        glyph: SettingGlyph.tune,
      ),
    ]);
  }

  static FormTag _promptsTag(PromptUse use) => switch (use) {
    PromptUse.local => const FormTag(
      "Stays on your machine",
      tone: NoticeTone.good,
    ),
    PromptUse.notTrained => const FormTag(
      "Doesn't train on prompts",
      tone: NoticeTone.good,
    ),
    PromptUse.dependsOnRoute => const FormTag("Training depends on the model"),
    PromptUse.trainedWhenFree => const FormTag(
      "Free tier trains on prompts",
      tone: NoticeTone.warning,
    ),
    PromptUse.unstated => const FormTag(
      "Free tier terms unclear",
      tone: NoticeTone.warning,
    ),
  };

  FormText _nameField(Map<String, String> a, LlmProvider? preset) {
    final name = _name(a);
    return FormText(
      "name",
      "Name",
      hint: preset?.displayName,
      helper: "What the model list calls it",
      error: name.isNotEmpty && nameTaken(name)
          ? "Another provider is called $name"
          : null,
      focused: provider == null && preset?.terms == null,
    );
  }

  /// What a preset needs from someone who does not know what a base URL is:
  /// the key, where to make one, and where the provider says what it does
  /// with the prompts. No technical word; those are under Advanced.
  List<FormFieldSpec> _plain(
    Map<String, String> a,
    LlmProvider preset,
    PresetTerms terms,
  ) {
    final service = preset.displayName;
    final keyless = !preset.needsKey;
    return [
      FormNote(
        keyless
            ? "$service runs on this computer, so there is nothing to type. "
                  "Start $service before you chat."
            : "Entoli needs an access key from your $service account to "
                  "talk to it. Create one on $service's website, copy it, "
                  "and paste it below.",
      ),
      if (terms.keyUrl case final url?)
        FormLink("Get a key from $service", Uri.parse(url), prominent: true),
      if (!keyless)
        FormText(
          "key",
          "Access key",
          secret: true,
          focused: provider == null,
          helper: storedKey != null
              ? "Leave empty to keep the key you saved"
              : "Kept private on this device",
        ),
      if (terms.policy case final policy?)
        FormLink("$service's privacy policy", Uri.parse(policy)),
      if (storedKey != null) _keep,
    ];
  }

  static const _keep = FormChoice("keep", label: "Saved key", [
    FormOption("keep", "Keep the saved key"),
    FormOption("", "Remove the saved key"),
  ]);

  /// The whole entry, in the terms the endpoint itself uses. A preset's key
  /// is above it, under its plain name, unless the preset is local: a local
  /// server can sit behind a key, so it is asked here.
  List<FormFieldSpec> _technical(Map<String, String> a, LlmProvider? preset) {
    final api = _api(a);
    final terms = preset?.terms;
    final keyless = preset != null && !preset.needsKey;
    final env = (provider ?? preset?.config)?.apiKeyEnv;
    return [
      if (preset == null)
        FormChoice("api", label: "API", [
          const FormOption("openai", "OpenAI-compatible"),
          const FormOption("anthropic", "Anthropic"),
          // A program run here — a desktop's own, or in Android's Linux —
          // which iOS cannot do; an entry synced onto it still shows what it
          // is.
          for (final cli in cliProviderPresets)
            if (cli.supported || provider?.api == cli.config.api)
              FormOption(cli.config.api.name, cli.config.displayName),
        ]),
      if (api.isCli) ...[
        FormNote(cliPresetOf(api).about),
        FormSignIn(_draft(a).config),
        FormText(
          "command",
          "Executable",
          hint: cliPresetOf(api).defaultCommand,
          helper: "Empty runs ${cliPresetOf(api).defaultCommand} from PATH",
          file: true,
        ),
        const FormEntries(
          "env",
          "Environment",
          helper: "What the program runs with, over the app's own.",
        ),
      ] else ...[
        FormText(
          "baseUrl",
          "Base URL",
          hint: preset?.config.baseUrl,
          helper: "The versioned root, e.g. https://api.openai.com/v1",
        ),
        if (terms == null || keyless) ...[
          FormText(
            "key",
            "API key",
            secret: true,
            helper: storedKey != null
                ? "Leave empty to keep the stored key"
                : env == null
                ? "Stored in the ${encrypted ? "OS keyring" : "app secret store"}"
                : "Leave empty to read \$$env from the environment",
          ),
          if (storedKey != null) _keep,
        ] else if (env != null && storedKey == null)
          FormNote(
            "With the access key left empty, \$$env is read from the "
            "environment.",
          ),
        const FormText(
          "modelsEndpoint",
          "Models endpoint",
          helper:
              "Empty lists the models models.dev has for it. Filled, lists "
              "this endpoint's instead, e.g. http://localhost:11434/v1/models.",
        ),
        FormText(
          "catalogId",
          "Provider ID",
          hint: preset?.config.catalogId,
          helper:
              "Its id on models.dev, which lists its models when the models "
              "endpoint is empty, e.g. google. Empty matches it by base URL.",
        ),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) {
    if (a["preset"] == _unpicked || _owed(_preset(a), a)) return "";
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
  ProviderDraft build(Map<String, String> a) => _draft(a);

  ProviderDraft _draft(Map<String, String> a) {
    final preset = _preset(a)?.config;
    final base = provider ?? preset;
    final api = _api(a);
    final name = _name(a);
    final id = a["id"]!;
    if (api.isCli) {
      final command = a["command"]!.trim();
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
        id: id,
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
