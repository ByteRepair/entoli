import "../../../core/log.dart";
import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../../../providers.dart";
import "package:uuid/uuid.dart";

import "../../provider_usage_words.dart";
import "../controller.dart";
import "../forms/provider.dart";
import "../spec.dart";

const _page = SettingsPageId.providers;

const _ollamaCloud = OllamaCloudProvider();

final providerSections = [
  // The nudge an empty page stands in for: gone the moment a provider of any
  // kind is configured.
  SectionSpec(
    page: _page,
    id: "recommended",
    title: "",
    weight: 0,
    shown: (ref) => ref.watch(appSettingsProvider).llmProviders.isEmpty,
  ),
  SectionSpec(
    page: _page,
    id: "providers",
    title: "Providers",
    weight: 10,
    keepEmpty: true,
    describe: (ref) => ref.watch(appSettingsProvider).llmProviders.isEmpty
        ? "None yet. The agent cannot answer until one is added."
        : "Where the models come from. Each is an endpoint, a key, and "
              "the models it offers.",
  ),
];

/// Whether it can answer, in plain words for a preset. An endpoint typed in
/// by hand is told apart by its address, which its owner knows.
String _status(SettingContext c, LlmProviderConfig config) {
  final provider = providerOf(config);
  final environment = c.ref.read(appSettingsProvider).environment;
  final processEnv = c.ref.read(processEnvProvider);
  final stored = c.ref.read(appSecretsProvider).providerKey(config.id);
  final hasKey =
      (stored != null && stored.isNotEmpty) ||
      config.resolveKeyWith((name) => environment[name] ?? processEnv(name)) !=
          null;
  final status = !provider.needsKey
      ? "On this computer"
      : hasKey
      ? "Connected"
      : "Needs a key";
  if (provider is CliProvider) return "${provider.command} · $status";
  return provider.terms == null ? "${config.baseUrl} · $status" : status;
}

final providerSettings = [
  // A recommended provider, the reason for it, and the two ways to act on
  // it: signing up, or pasting a key already in hand. The key goes to the
  // store, never onto the config.
  SettingSpec(
    id: "recommendedProvider",
    path: (page: _page, section: "recommended"),
    weight: 0,
    title: "Recommended provider",
    hint: UiHint.recommended,
    build: (c) {
      final notifier = c.ref.read(appSettingsProvider.notifier);
      return GroupController(
        c.spec,
        children: [
          NoticeController(
            c.part("why", "Ollama Cloud", hint: UiHint.notice).spec,
            lines: [
              const NoticeLine(
                "Entoli works with both privacy-respecting and other "
                "providers. We recommend Ollama Cloud: it does not keep or "
                "train on your prompts and outputs.",
              ),
              NoticeLine(
                "Sign up",
                url: Uri.parse("https://signin.ollama.com/sign-up"),
              ),
              NoticeLine(
                "Ollama Cloud privacy policy",
                url: Uri.parse(_ollamaCloud.terms!.policy!),
              ),
            ],
          ),
          TextController(
            c.part("key", "Already have a key?", hint: UiHint.input).spec,
            value: "",
            prompt: "Ollama API key",
            secret: true,
            submitLabel: "Add Ollama Cloud",
            onSet: (key) async {
              final trimmed = key.trim();
              if (trimmed.isEmpty) return null;
              await notifier.upsertProvider(
                _ollamaCloud.config,
                setKey: trimmed,
              );
              return null;
            },
          ),
        ],
      );
    },
  ),
  SettingSpec(
    id: "providers",
    path: (page: _page, section: "providers"),
    weight: 0,
    title: "Providers",
    hint: UiHint.providers,
    glyph: SettingGlyph.add,
    build: (c) {
      final providers = c.ref.watch(appSettingsProvider).llmProviders;
      final notifier = c.ref.read(appSettingsProvider.notifier);
      final now = DateTime.now();
      ProviderForm form(LlmProviderConfig? provider) =>
          providerForm(c.ref, provider);
      return CollectionController<LlmProviderConfig>(
        c.spec,
        items: providers,
        addLabel: "Add provider",
        describe: (provider) => CollectionItem(
          provider.displayName,
          id: provider.id,
          // What it has spent of its allowance, where it says.
          subtitle: [
            _status(c, provider),
            for (final usage
                in c.ref.watch(providerUsageProvider(provider.id)).value ??
                    const [])
              describeUsage(usage, now),
          ].join("\n"),
          removeLabel: "Remove ${provider.displayName}",
        ),
        form: (provider) => _ConfigForm(form(provider)),
        onSet: notifier.setProviders,
        submit: (answers, index) => saveProvider(
          c.ref,
          form(index == null ? null : providers[index]),
          answers,
        ),
      );
    },
  ),
];

/// The form [provider] is added or edited through, or a new one started on
/// [preset].
ProviderForm providerForm(
  SettingReader ref,
  LlmProviderConfig? provider, {
  LlmProvider? preset,
}) {
  final secrets = ref.read(appSecretsProvider);
  final programs = ref.read(cliProgramsProvider);
  return ProviderForm(
    provider,
    preset: preset,
    nameTaken: (name) => ref
        .read(appSettingsProvider)
        .providerNameTaken(name, exceptId: provider?.id),
    storedKey: provider == null ? null : secrets.providerKey(provider.id),
    encrypted: secrets.encrypted,
    newId: const Uuid().v4(),
    // A new entry given up on: its folders under every program go, and any
    // sign-in made in them, the form having perhaps been switched to another
    // program first.
    forget: (id) async {
      for (final cli in programs) {
        await cli.withConfig(cli.config.copyWith(id: id)).forget();
      }
    },
  );
}

/// Saves what [form] was answered with. A typed key is put to the provider
/// first: one it refuses is said on the key, and saving the same again keeps
/// it anyway; one it could not be asked about is saved, since no answer is
/// not a no. [adopt] has it answer new chats at its own defaults.
Future<void> saveProvider(
  SettingReader ref,
  ProviderForm form,
  Map<String, String> answers, {
  bool adopt = false,
}) async {
  final notifier = ref.read(appSettingsProvider.notifier);
  final draft = form.build(answers);
  final key = draft.setKey;
  if (key != null && key.isNotEmpty && answers["anyway"] != formYes) {
    bool? accepted;
    try {
      accepted = await ref.read(keyCheckProvider)(draft.config, key);
    } catch (e) {
      logFailure("llm", "checking ${draft.config.id}'s key failed", e);
    }
    if (accepted == false) {
      final service = presetOf(draft.config)?.displayName ?? "The provider";
      throw FormRefusal(
        "key",
        "$service did not accept this key. Check it was copied whole.",
        anyway: "anyway",
        anywayLabel: "Save anyway",
      );
    }
  }
  await notifier.upsertProvider(draft.config, setKey: key, adopt: adopt);
}

/// [ProviderForm] as a form over the configs themselves, what the list
/// edits; what a submit saves is the whole draft, the key with it.
class _ConfigForm extends SettingForm<LlmProviderConfig> {
  _ConfigForm(this._form);

  final ProviderForm _form;

  @override
  String get title => _form.title;

  @override
  Map<String, String> get initial => _form.initial;

  @override
  List<FormFieldSpec> fields(Map<String, String> answers) =>
      _form.fields(answers);

  @override
  String? problem(Map<String, String> answers) => _form.problem(answers);

  @override
  LlmProviderConfig build(Map<String, String> answers) =>
      _form.build(answers).config;
}
