import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/platform/default_backend.dart";
import "../../domain/llm_provider.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
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
          _HarnessSection(),
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

/// What a new chat gets. The backend it runs on is fixed once it is created;
/// the model is a live reference, so retargeting it retargets every chat that
/// pinned nothing.
class _DefaultsSection extends ConsumerWidget {
  const _DefaultsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final available = ref.watch(availableBackendsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader("New chats"),
        // A platform with one backend has nothing to ask about, and a picker
        // with a single option reads as a setting that does not work.
        if (available.length > 1)
          InheritableDropdown<BackendKind>(
            label: "Default backend",
            value: settings.defaultBackend,
            inherited: backendLabel(defaultBackendKind()),
            options: {for (final kind in available) kind: backendLabel(kind)},
            onChanged: (kind) =>
                ref.read(appSettingsProvider.notifier).setDefaultBackend(kind),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          // Nothing above the app level to inherit from: Default means
          // whatever the backend picks.
          child: ModelPicker(
            choice: (
              providerId: settings.defaultProviderId,
              modelId: settings.defaultModelId,
            ),
            onChanged: (choice) =>
                ref.read(appSettingsProvider.notifier).setDefault(choice),
          ),
        ),
      ],
    );
  }
}

/// mini-swe-agent, ported into agent-chat and running in this process: the
/// endpoints it calls and whether it asks before doing anything.
class _HarnessSection extends ConsumerWidget {
  const _HarnessSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          "Built-in harness",
          description: "mini-swe-agent, running inside agent-chat. Nothing to install: "
              "it calls the model itself and runs its commands in the chat's workspace.",
        ),
        SwitchListTile(
          value: settings.approveCommands,
          onChanged: (value) =>
              ref.read(appSettingsProvider.notifier).setApproveCommands(value),
          title: const Text("Ask before running commands"),
          subtitle: const Text("Every command waits for you. A chat can override this."),
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
              ? "None yet. The harness cannot answer until one is added."
              : null,
        ),
        for (final provider in providers)
          ListTile(
            dense: true,
            title: Text(provider.displayName),
            subtitle: Text(_describe(provider)),
            onTap: () => _upsert(context, ref,
                initial: provider, title: "Edit ${provider.displayName}"),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove ${provider.id}",
              onPressed: () => _remove(ref, provider),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: MenuAnchor(
            menuChildren: [
              // One already configured is edited from its row rather than
              // added again.
              for (final preset in llmProviderPresets)
                if (!configured.contains(preset.id))
                  MenuItemButton(
                    onPressed: () => _upsert(context, ref, initial: preset),
                    child: Text(preset.displayName),
                  ),
              MenuItemButton(
                onPressed: () => _upsert(context, ref),
                child: const Text("Custom…"),
              ),
            ],
            builder: (context, controller, _) => OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Add provider"),
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
        ),
      ],
    );
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

/// The environment every opencode server is started with, and that the built-in
/// harness runs its commands under.
class _EnvironmentSection extends ConsumerWidget {
  const _EnvironmentSection();

  Future<void> _edit(BuildContext context, WidgetRef ref, {String? name}) async {
    final env = ref.read(appSettingsProvider).opencodeEnv;
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
    await ref.read(appSettingsProvider.notifier).setOpencodeEnv(next);
  }

  Future<void> _remove(WidgetRef ref, String name) async {
    final next = {...ref.read(appSettingsProvider).opencodeEnv}..remove(name);
    await ref.read(appSettingsProvider.notifier).setOpencodeEnv(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(appSettingsProvider).opencodeEnv;
    final names = env.keys.toList()..sort();
    final hasOpencode = ref.watch(availableBackendsProvider).contains(BackendKind.opencode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          "Environment",
          description: hasOpencode
              ? "Passed to every opencode server, and to the commands the built-in "
                  "harness runs. A chat already running keeps what it started with."
              : "Passed to the commands the built-in harness runs. A chat already "
                  "running keeps what it started with.",
        ),
        for (final name in names)
          ListTile(
            dense: true,
            title: Text(name),
            // These are mostly API keys, and settings is a page people show
            // people.
            subtitle: Text("•" * env[name]!.length.clamp(0, 24)),
            onTap: () => _edit(context, ref, name: name),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove $name",
              onPressed: () => _remove(ref, name),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
