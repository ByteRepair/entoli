
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/editable_row.dart";
import "../widgets/side_panel_frame.dart";
import "../widgets/section_header.dart";
import "agents_settings.dart";
import "byte_repair_settings.dart";
import "connect_provider.dart";
import "running_models.dart";
import "local_model_settings.dart";
import "provider_usage_view.dart";
import "on_device_catalog.dart";
import "provider_picker.dart";
import "triggers.dart";
import "skills_settings.dart";
import "settings_category.dart";
import "schema_view.dart";
import "../../app/settings/spec.dart";
import "welcome_page.dart";
import "../widgets/page_bar.dart";

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialCategory, this.focus = false});

  final SettingsCategory? initialCategory;

  /// Pushed for one category — the welcome tour's setup rows, the Byte Repair
  /// bar — rather than arrived at through the settings list. That category is
  /// the whole page on a wide window too, with nothing behind it: back leaves
  /// settings rather than a list it skipped, and the panel is not drawn
  /// beside what it was not used to pick.
  final bool focus;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// General until something else is picked, so a wide window always has a
  /// category beside the list and a narrow one has it highlighted there.
  late SettingsCategory _category =
      widget.initialCategory ?? SettingsCategory.general;

  /// Whether the category is in front of the list in a narrow window. Kept
  /// whatever the width, so a window narrowed after a pick lands on what the
  /// user was reading rather than back on the list. A named category opens
  /// in front; otherwise the list is what settings shows first.
  late bool _categoryShown = widget.initialCategory != null;

  /// Back from a category to the list, by the bar's button or the back key.
  void _showList() => setState(() => _categoryShown = false);

  @override
  Widget build(BuildContext context) {
    // A category this platform does not offer is not opened, whoever names it.
    if (widget.initialCategory case final initial?
        when widget.focus && initial.offered(ref)) {
      return Scaffold(
        appBar: PageBar(title: initial.label),
        body: _categoryBody(initial),
      );
    }
    final category = _category.offered(ref)
        ? _category
        : SettingsCategory.general;
    return SidePanelFrame(
      narrow: SidePanelNarrow.page,
      contentShown: _categoryShown,
      onHideContent: _showList,
      // The list is settings' own structure, so it is never hidden: nothing
      // takes the bar's leading slot from its back button. In front of the
      // list the button is drawn whatever is under the route, since it goes
      // back to the list rather than out of settings.
      bar: (mode) => mode == SidePanelMode.contentPage
          ? PageBar(title: category.label, onBack: _showList)
          : PageBar(title: "Settings"),
      panel: _Categories(
        selected: category,
        onSelect: (picked) => setState(() {
          _category = picked;
          _categoryShown = true;
        }),
      ),
      child: _categoryBody(category, key: ValueKey(category)),
    );
  }
}

/// What a category draws in either layout. Welcome is the tour, a pager with
/// its own bar that cannot scroll in a list, and Skills and Agents scroll
/// their own list to keep their footers fixed to the bottom — everything
/// else is its sections.
Widget _categoryBody(SettingsCategory category, {Key? key}) =>
    switch (category) {
      SettingsCategory.welcome => const WelcomeTour(),
      SettingsCategory.skills => const SkillsSection(),
      SettingsCategory.agents => const AgentsSection(),
      _ => ListView(key: key, children: _sectionsOf(category)),
    };

/// What is filed under a category, whether it is drawn beside the list or on a
/// page of its own. [SettingsCategory.welcome] is not filed anywhere: the tour
/// is a body of its own, which [_categoryBody] renders whole.
List<Widget> _sectionsOf(SettingsCategory category) => switch (category) {
  SettingsCategory.general => const [SchemaSections(SettingsPageId.general)],
  // Its own category for the reason Voice is one: the picker is a line and
  // the catalog under it is the rest of the page.
  SettingsCategory.terminal => const [SchemaSections(SettingsPageId.terminal)],
  // Beside Terminal rather than under LLMs, and for the same reason it is:
  // what is picked is two lines and the catalog under it is the rest of the
  // page. Where a model runs is also a machine question rather than a
  // question about models — the LLMs category is what a chat is answered
  // by, and a model here appears there like any other.
  // Every download, text and speech: Voice and LLMs only pick, and offer
  // what is here beside the providers' models.
  SettingsCategory.onDevice => const [
    // What is loaded leads the page: it is what is most often come here for,
    // and three taps deep under LLM settings was too far.
    RunningModelsSection(),
    LocalModelSection(),
    // Draws its own dividers, since a kind nothing here can run has no
    // catalog to put under one.
    OnDeviceCatalog(),
  ],
  SettingsCategory.voice => const [SchemaSections(SettingsPageId.voice)],
  SettingsCategory.triggers => const [TriggersSection()],
  // Rendered by [_categoryBody] whole rather than filed here, for the
  // footers pinned to their bottoms.
  SettingsCategory.skills => const [],
  SettingsCategory.agents => const [],
  SettingsCategory.agentBrowser => const [
    SchemaSections(SettingsPageId.agentBrowser),
  ],
  SettingsCategory.byteRepair => const [ByteRepairSection()],
  SettingsCategory.sync => const [SchemaSections(SettingsPageId.sync)],
  SettingsCategory.providers => const [_ProvidersEditor()],
  // The agent's own settings are under LLMs, beside the model it runs: the
  // classifier picker travels with the mode because auto mode is unusable
  // without one.
  SettingsCategory.llms => const [SchemaSections(SettingsPageId.llms)],
  SettingsCategory.images => const [SchemaSections(SettingsPageId.images)],
  // The two things the agent carries between conversations: the files the
  // user writes (instructions) and the ones it writes (memories).
  SettingsCategory.memory => const [SchemaSections(SettingsPageId.memory)],
  SettingsCategory.data => const [SchemaSections(SettingsPageId.data)],
  SettingsCategory.shortcuts => const [
    SchemaSections(SettingsPageId.shortcuts),
  ],
  SettingsCategory.about => const [SchemaSections(SettingsPageId.about)],
  // Rendered by [_categoryBody] rather than filed here: the tour is a
  // pager with its own bar, not a list of sections.
  SettingsCategory.welcome => const [],
};

/// The categories as a list: beside the page where there is room for one, and
/// the page itself where there is not. Material, not Scaffold, since the
/// frame owns that.
class _Categories extends ConsumerWidget {
  const _Categories({required this.selected, required this.onSelect});

  final SettingsCategory selected;
  final ValueChanged<SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    child: SafeArea(
      child: ListView(
        children: [
          for (final category in SettingsCategory.values)
            if (category.offered(ref)) ...[
              if (category.dividerAbove) const Divider(),
              ListTile(
                selected: category == selected,
                leading: Icon(category.icon),
                title: Text(category.label),
                onTap: () => onSelect(category),
              ),
            ],
        ],
      ),
    ),
  );
}

/// The nudge an empty Providers page stands in for: a recommended provider,
/// the reason for it, and the two ways to act on it — signing up, or pasting
/// a key already in hand. Gone the moment a provider of any kind is configured.
class _RecommendedProvider extends ConsumerStatefulWidget {
  const _RecommendedProvider();

  @override
  ConsumerState<_RecommendedProvider> createState() =>
      _RecommendedProviderState();
}

class _RecommendedProviderState extends ConsumerState<_RecommendedProvider> {
  static final _signUp = Uri.parse("https://signin.ollama.com/sign-up");

  static const _ollamaCloud = OllamaCloudProvider();
  static final _privacy = Uri.parse(_ollamaCloud.terms!.policy!);

  final _apiKey = TextEditingController();

  @override
  void dispose() {
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _addWithKey() async {
    final key = _apiKey.text.trim();
    if (key.isEmpty) return;
    // Notifier first: adding the provider unmounts this card on the next
    // frame, and the save must outlive it rather than resume on a defunct
    // ref. The key goes to the store (setKey), never onto the config.
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.upsertProvider(_ollamaCloud.config, setKey: key);
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _apiKey.text.trim().isNotEmpty;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Entoli works with both privacy-respecting and other providers. "
              "We recommend Ollama Cloud: it does not keep or train on your "
              "prompts and outputs.",
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, _signUp),
              child: const Text("Sign up"),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, _privacy),
              child: const Text("Ollama Cloud privacy policy"),
            ),
            const Divider(height: 32),
            const Text("Already have a key?"),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKey,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: "Ollama API key"),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasKey ? _addWithKey : null,
              child: const Text("Add Ollama Cloud"),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProvidersEditor extends ConsumerWidget {
  const _ProvidersEditor();

  Future<void> _remove(WidgetRef ref, LlmProviderConfig provider) async {
    final providers = ref
        .read(appSettingsProvider)
        .llmProviders
        .where((p) => p.id != provider.id)
        .toList();
    await ref.read(appSettingsProvider.notifier).setProviders(providers);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(appSettingsProvider).llmProviders;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (providers.isEmpty) const _RecommendedProvider(),
        SectionHeader(
          "Providers",
          description: providers.isEmpty
              ? "None yet. The agent cannot answer until one is added."
              : "Where the models come from. Each is an endpoint, a key, and "
                    "the models it offers.",
        ),
        for (final provider in providers)
          EditableRow(
            title: provider.displayName,
            subtitle: _describe(ref, provider),
            removeLabel: "Remove ${provider.displayName}",
            onTap: () => editProvider(
              context,
              ref,
              initial: provider,
              title: "Edit ${provider.displayName}",
            ),
            onRemove: () => _remove(ref, provider),
            detail: ProviderUsageView(provider.id),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add provider"),
            onPressed: () => _add(context, ref),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final chosen = await pickProviderPreset(context);
    if (chosen != null && context.mounted) {
      final preset = chosen.preset;
      await editProvider(
        context,
        ref,
        initial: preset,
        title: preset == null
            ? "Add provider"
            : "Connect ${preset.displayName}",
      );
    }
  }

  /// Whether it can answer, in plain words for a preset. An endpoint typed in
  /// by hand is told apart by its address, which its owner knows.
  String _describe(WidgetRef ref, LlmProviderConfig config) {
    final provider = providerOf(config);
    final environment = ref.read(appSettingsProvider).environment;
    final processEnv = ref.read(processEnvProvider);
    final stored = ref.read(appSecretsProvider).providerKey(config.id);
    final hasKey =
        (stored != null && stored.isNotEmpty) ||
        config.resolveKeyWith(
              (name) => environment[name] ?? processEnv(name),
            ) !=
            null;
    final status = !provider.needsKey
        ? "On this computer"
        : hasKey
        ? "Connected"
        : "Needs a key";
    if (provider is CliProvider) return "${provider.command} · $status";
    return provider.terms == null ? "${config.baseUrl} · $status" : status;
  }
}
