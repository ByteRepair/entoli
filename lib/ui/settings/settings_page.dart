import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_icon.dart";
import "../../domain/llm_provider.dart";
import "../../domain/permission.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../widgets/anchored_menu.dart";
import "../widgets/app_mark.dart";
import "../widgets/dialogs.dart";
import "../widgets/provider_dialog.dart";
import "../widgets/provider_model_selector.dart";
import "../widgets/resettable_field.dart";

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(
        children: const [
          _DefaultsSection(),
          Divider(),
          _AppearanceSection(),
          Divider(),
          _AgentSection(),
          Divider(),
          _EnvironmentSection(),
          Divider(),
          _DeleteAllChats(),
        ],
      ),
    );
  }
}

/// A section heading and, under it, a line saying what the section is for.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.description, this.minor = false});

  final String title;
  final String? description;

  /// A heading inside a section rather than one of its own.
  final bool minor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: minor ? theme.textTheme.titleSmall : theme.textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(appSettingsProvider).appIcon;
    final switchesLauncher = ref.watch(launcherIconsProvider).available;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          "Appearance",
          description: switchesLauncher
              ? "The app icon, here and on the home screen."
              : "The app icon. The launcher's own icon is set when the app is "
                  "installed, so it does not follow this.",
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            spacing: 12,
            children: [
              for (final icon in AppIcon.values)
                _IconChoice(
                  icon: icon,
                  selected: icon == selected,
                  onTap: () =>
                      ref.read(appSettingsProvider.notifier).setAppIcon(icon),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final AppIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Tooltip(
        message: icon.description,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 104,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                AppIconImage(icon, size: 48),
                const SizedBox(height: 10),
                Text(icon.label, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a new chat gets. A live reference, not a snapshot: retargeting it
/// retargets every chat that pinned nothing.
class _DefaultsSection extends ConsumerWidget {
  const _DefaultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader("New chats"),
        // Nothing above the app level to inherit from: Default means whatever
        // the backend picks.
        LabelledField(
          label: "LLM",
          child: ModelPicker(
            choice: (
              providerId: settings.defaultProviderId,
              modelId: settings.defaultModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setDefault(choice),
          ),
        ),
        LabelledField(
          label: "Title LLM",
          child: OptionalModelPicker(
            offLabel: "Off",
            helperText: "Names a chat from its first message. Off, chats stay "
                "\"New chat\" until you rename them.",
            choice: (
              providerId: settings.titleProviderId,
              modelId: settings.titleModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setTitleModel(choice),
          ),
        ),
      ],
    );
  }
}

/// The endpoints the agent calls and how it gates commands.
class _AgentSection extends ConsumerWidget {
  const _AgentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final noClassifier = settings.classifierProviderId == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Agent",
          description: "mini-swe-agent, running inside Entoli. It calls the model "
              "itself and runs its commands in the chat's workspace.",
        ),
        LabelledField(
          label: "Running commands",
          child: DropdownButtonFormField<ApproveMode>(
            initialValue: settings.approveMode,
            isExpanded: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              helperText: settings.approveMode == ApproveMode.auto && noClassifier
                  ? "No classifier model set — auto mode will ask for every command."
                  : null,
            ),
            items: [
              for (final entry in approveModeLabels.entries)
                DropdownMenuItem(
                  value: entry.key,
                  enabled: entry.key != ApproveMode.auto || !noClassifier,
                  child: Text(entry.value),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                ref.read(appSettingsProvider.notifier).setApproveMode(value);
              }
            },
          ),
        ),
        LabelledField(
          label: "Classifier LLM",
          child: OptionalModelPicker(
            offLabel: "Off",
            helperText: "Classifies commands as safe, dangerous, or uncertain. "
                "Off, auto mode asks for every command.",
            choice: (
              providerId: settings.classifierProviderId,
              modelId: settings.classifierModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setClassifierModel(choice),
          ),
        ),
        const _ProvidersEditor(),
      ],
    );
  }
}

class _ProvidersEditor extends ConsumerWidget {
  const _ProvidersEditor();

  /// One upsert for both routes in: editing an entry and adding one that turns
  /// out to share an id mean the same thing, and two entries under one name
  /// would show the same models twice.
  Future<void> _upsert(
    BuildContext context,
    WidgetRef ref, {
    LlmProviderConfig? initial,
    String title = "Add provider",
  }) async {
    final saved = await promptForProvider(context, initial: initial, title: title);
    if (saved == null) return;
    final providers = [
      ...ref.read(appSettingsProvider).llmProviders.where((p) => p.id != saved.id),
      saved,
    ];
    await ref.read(appSettingsProvider.notifier).setProviders(providers);
  }

  Future<void> _remove(WidgetRef ref, LlmProviderConfig provider) async {
    final providers =
        ref.read(appSettingsProvider).llmProviders.where((p) => p.id != provider.id).toList();
    await ref.read(appSettingsProvider.notifier).setProviders(providers);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(appSettingsProvider).llmProviders;
    final configured = providers.map((p) => p.id).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          "Providers",
          minor: true,
          description: providers.isEmpty
              ? "None yet. The agent cannot answer until one is added."
              : null,
        ),
        for (final provider in providers)
          _EditableRow(
            title: provider.displayName,
            subtitle: _describe(provider),
            removeLabel: "Remove ${provider.id}",
            onTap: () => _upsert(context, ref,
                initial: provider, title: "Edit ${provider.displayName}"),
            onRemove: () => _remove(ref, provider),
          ),
        _AddButtonRow(
          // The button's own context, which is what the menu is anchored under.
          child: Builder(
            builder: (context) => OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Add provider"),
              onPressed: () => _add(context, ref, configured),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref, Set<String> configured) async {
    final chosen = await showAnchoredMenu<VoidCallback>(context, [
      // One already configured is edited from its row rather than added again.
      for (final preset in llmProviderPresets)
        if (!configured.contains(preset.id))
          PopupMenuItem(
            value: () => _upsert(context, ref, initial: preset),
            child: Text(preset.displayName),
          ),
      PopupMenuItem(
        value: () => _upsert(context, ref),
        child: const Text("Custom…"),
      ),
    ]);
    if (context.mounted) chosen?.call();
  }

  String _describe(LlmProviderConfig provider) {
    final key = provider.apiKey.isNotEmpty
        ? "key set"
        : provider.apiKeyEnv != null
            ? "\$${provider.apiKeyEnv}"
            : "no key";
    final models =
        provider.models.isEmpty ? "models from endpoint" : "${provider.models.length} models";
    return "${provider.baseUrl} · $key · $models";
  }
}

/// What the agent's commands run under, and where a provider that names its
/// key rather than holding it looks.
class _EnvironmentSection extends ConsumerWidget {
  const _EnvironmentSection();

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? name}) async {
    final env = ref.read(appSettingsProvider).environment;
    final pair = await promptForPair(
      context,
      title: name == null ? "Add variable" : "Edit $name",
      nameLabel: "Name",
      valueLabel: "Value",
      name: name ?? "",
      value: name == null ? "" : env[name] ?? "",
    );
    if (pair == null) return;
    // A rename drops the old key rather than leaving both behind.
    final next = {...env}..remove(name);
    next[pair.name] = pair.value;
    await ref.read(appSettingsProvider.notifier).setEnvironment(next);
  }

  Future<void> _remove(WidgetRef ref, String name) async {
    final next = {...ref.read(appSettingsProvider).environment}..remove(name);
    await ref.read(appSettingsProvider.notifier).setEnvironment(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(appSettingsProvider).environment;
    final names = env.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Environment",
          description: "Passed to every command the agent runs. A command already "
              "running keeps what it started with.",
        ),
        for (final name in names)
          _EditableRow(
            title: name,
            // These are mostly API keys, and settings is a page people show
            // people.
            subtitle: "•" * env[name]!.length.clamp(0, 24),
            removeLabel: "Remove $name",
            onTap: () => _edit(context, ref, name: name),
            onRemove: () => _remove(ref, name),
          ),
        _AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add variable"),
            onPressed: () => _edit(context, ref),
          ),
        ),
      ],
    );
  }
}

/// One entry in an editable list: tap the row to change it, the cross to drop
/// it. Both list sections here are the same affordance over different data.
class _EditableRow extends StatelessWidget {
  const _EditableRow({
    required this.title,
    required this.subtitle,
    required this.removeLabel,
    required this.onTap,
    required this.onRemove,
  });

  final String title;
  final String subtitle;
  final String removeLabel;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: onTap,
        trailing: IconButton(
          icon: const Icon(Icons.close),
          tooltip: removeLabel,
          onPressed: onRemove,
        ),
      );
}

class _AddButtonRow extends StatelessWidget {
  const _AddButtonRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: child);
}

class _DeleteAllChats extends ConsumerWidget {
  const _DeleteAllChats();

  Future<void> _confirmAndDelete(BuildContext context, WidgetRef ref) async {
    final count = (await ref.read(chatRepositoryProvider).listChats()).length;
    if (!context.mounted) return;

    final confirmed = await confirm(
      context,
      title: "Delete all chats?",
      message: count == 0
          ? "There are no chats to delete."
          : "This permanently removes $count ${count == 1 ? "chat" : "chats"}, "
              "including their workspaces. It cannot be undone.",
      confirmLabel: count == 0 ? null : "Delete all",
      destructive: true,
    );
    if (!confirmed) return;

    ref.read(selectedChatIdProvider.notifier).select(null);
    await ref.read(chatRepositoryProvider).deleteAllChats();
    ref.invalidate(chatListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        icon: const Icon(Icons.delete_forever),
        label: const Text("Delete all chats"),
        onPressed: () => _confirmAndDelete(context, ref),
      ),
    );
  }
}
