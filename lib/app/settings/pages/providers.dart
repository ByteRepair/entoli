import "../../../data/builtin/llm/providers/presets.dart";
import "../../../domain/llm_provider.dart";
import "../../../providers.dart";
import "package:uuid/uuid.dart";

import "../../provider_usage_words.dart";
import "../controller.dart";
import "../hand_off.dart";
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
            SettingSpec(
              id: "recommendedProvider.why",
              path: c.spec.path,
              weight: 0,
              title: "Ollama Cloud",
              hint: UiHint.notice,
              build: c.spec.build,
            ),
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
            SettingSpec(
              id: "recommendedProvider.key",
              path: c.spec.path,
              weight: 0,
              title: "Already have a key?",
              hint: UiHint.input,
              build: c.spec.build,
            ),
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
      final settings = c.ref.read(appSettingsProvider);
      final secrets = c.ref.read(appSecretsProvider);
      final check = c.ref.read(keyCheckProvider);
      final handOff = c.ref.read(settingsHandOffProvider);
      final now = DateTime.now();
      ProviderForm form(LlmProviderConfig? provider) => ProviderForm(
        provider,
        nameTaken: (name) =>
            settings.providerNameTaken(name, exceptId: provider?.id),
        storedKey: provider == null ? null : secrets.providerKey(provider.id),
        encrypted: secrets.encrypted,
      );
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
          actions: [
            if (provider.api.isCli && handOff.signIn != null) ...[
              const ItemAction("signIn", "Sign in", handsOff: true),
              const ItemAction("signInAgain", "Sign in again", handsOff: true),
            ],
          ],
        ),
        form: (provider) => _ConfigForm(form(provider)),
        onSet: notifier.setProviders,
        // A key the provider refuses is said, and saving the same one again
        // keeps it anyway.
        submit: (answers, index) async {
          final editing = index == null ? null : providers[index];
          final draft = form(editing).build(answers);
          final key = draft.setKey;
          if (key != null && key.isNotEmpty && !_refused.remove(key)) {
            bool? accepted;
            try {
              accepted = await check(draft.config, key);
            } catch (_) {}
            if (accepted == false) {
              _refused.add(key);
              throw const _Refused();
            }
          }
          await notifier.upsertProvider(
            draft.config.copyWith(id: editing?.id ?? const Uuid().v4()),
            setKey: key,
          );
        },
        act: (index, action) async {
          await handOff.signIn?.call(
            providers[index],
            again: action == "signInAgain",
          );
          return null;
        },
      );
    },
  ),
];

/// Keys a provider refused once: the next save of the same one keeps it.
final _refused = <String>{};

class _Refused implements Exception {
  const _Refused();

  @override
  String toString() =>
      "The provider did not accept this key. Check it was copied whole, or "
      "save again to keep it anyway.";
}

/// [ProviderForm] as a form over the configs themselves, what the list
/// edits; what a submit saves is the whole draft, the key with it.
class _ConfigForm implements SettingForm<LlmProviderConfig> {
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
