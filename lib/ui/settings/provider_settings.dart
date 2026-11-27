import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/provider_usage.dart";
import "package:entoli_core/view/widgets/busy.dart";
import "package:entoli_core/view/widgets/dialogs.dart" show confirm;

import "../../app/provider_usage_words.dart";
import "../../app/settings/cli_account.dart" show forgetCliEntry;
import "../../app/settings/provider_edit.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../providers.dart";
import "../widgets/add_button_row.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";
import "provider_dialog.dart";
import "provider_picker.dart";

/// [ProviderDialog] over [provider], or a new entry on [preset] (none for one
/// typed in by hand), saved through the settings notifier. [adopt] has it
/// answer new chats at its own defaults: the welcome tour's connect.
///
/// A new entry is given its id before the dialog opens: a CLI's account is
/// kept in a folder named by it, and the dialog can sign one in before Save.
/// Cancelled, a new entry's folders go, and any sign-in made in them.
/// Whether it was saved.
Future<bool> editProvider(
  BuildContext context, {
  LlmProviderConfig? provider,
  LlmProvider? preset,
  bool adopt = false,
}) async {
  // Read now: the page that asked can go away while the dialog is open, and
  // the save must outlive it.
  final container = ProviderScope.containerOf(context, listen: false);
  final notifier = container.read(appSettingsProvider.notifier);
  final secrets = container.read(appSecretsProvider);
  final programs = container.read(cliProgramsProvider);
  final edit = ProviderEdit(
    provider,
    preset: preset,
    id: provider?.id ?? const Uuid().v4(),
    nameTaken: (name) => container
        .read(appSettingsProvider)
        .providerNameTaken(name, exceptId: provider?.id),
    storedKey: provider == null ? null : secrets.providerKey(provider.id),
  );
  final draft = await showDialog<ProviderDraft>(
    context: context,
    builder: (_) => ProviderDialog(edit, encrypted: secrets.encrypted),
  );
  if (draft == null) {
    if (edit.adding) await forgetCliEntry(programs, edit.id);
    return false;
  }
  await notifier.upsertProvider(
    draft.config,
    setKey: draft.setKey,
    adopt: adopt,
  );
  return true;
}

/// The Providers category: where the models come from, each an endpoint, a
/// key and what it offers, with a recommended one standing in for an empty
/// list.
class ProvidersSection extends ConsumerWidget {
  const ProvidersSection({super.key});

  /// Asked first: the key and a program's sign-in go with it, and neither
  /// comes back with a second Add.
  Future<void> _remove(BuildContext context, LlmProviderConfig provider) async {
    // Read now: the section can be rebuilt away while the dialog is open.
    final container = ProviderScope.containerOf(context, listen: false);
    final gone = provider.api.isCli
        ? "Its sign-in on this device goes with it, and anything"
        : providerOf(provider).needsKey
        ? "Its saved key goes with it, and anything"
        : "Anything";
    final sure = await confirm(
      context,
      title: "Remove ${provider.displayName}?",
      message: "$gone set to its models falls back to the default.",
      confirmLabel: "Remove",
      destructive: true,
    );
    if (!sure) return;
    final providers = container
        .read(appSettingsProvider)
        .llmProviders
        .where((p) => p.id != provider.id)
        .toList();
    await container.read(appSettingsProvider.notifier).setProviders(providers);
  }

  Future<void> _add(BuildContext context) async {
    await showProviderPicker(
      context,
      connect: (context, preset) => editProvider(context, preset: preset),
    );
  }

  String _status(WidgetRef ref, LlmProviderConfig config) {
    final environment = ref.read(appSettingsProvider).environment;
    final processEnv = ref.read(processEnvProvider);
    return providerStatus(
      config,
      storedKey: ref.read(appSecretsProvider).providerKey(config.id),
      env: (name) => environment[name] ?? processEnv(name),
    );
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
            subtitle: _status(ref, provider),
            removeLabel: "Remove ${provider.displayName}",
            onTap: () => guarded(
              context,
              () => editProvider(context, provider: provider),
            ),
            onRemove: () => guarded(context, () => _remove(context, provider)),
            detail: ProviderUsageView(provider.id),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add provider"),
            onPressed: () => guarded(context, () => _add(context)),
          ),
        ),
      ],
    );
  }
}

/// The nudge an empty Providers page stands in for: a recommended provider,
/// the reason for it, and the two ways to act on it, signing up or pasting a
/// key already in hand. Gone the moment a provider of any kind is configured.
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
    // frame, and the save must outlive it. The key goes to the store.
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
              onSubmitted: (_) => guarded(context, _addWithKey),
              decoration: const InputDecoration(labelText: "Ollama API key"),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: hasKey ? () => guarded(context, _addWithKey) : null,
              child: const Text("Add Ollama Cloud"),
            ),
          ],
        ),
      ),
    );
  }
}

/// A configured provider's allowances, one bar each, under its row. Nothing
/// at all while it is being asked or where the provider says nothing, which
/// is most of them.
class ProviderUsageView extends ConsumerWidget {
  const ProviderUsageView(this.providerId, {super.key});

  final String providerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usages =
        ref.watch(providerUsageProvider(providerId)).value ?? const [];
    if (usages.isEmpty) return const SizedBox.shrink();
    final now = ref.read(clockProvider).now();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final usage in usages)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(describeUsage(usage, now)),
                  // A balance has nothing to measure it against, so no bar.
                  if (usage is UsageWindow) ...[
                    const SizedBox(height: 2),
                    LinearProgressIndicator(
                      value: usage.fraction,
                      semanticsLabel: usage.label,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
