import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../widgets/dialogs.dart";
import "../widgets/provider_model_selector.dart";

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kind = ref.watch(agentBackendProvider).kind;
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.memory),
            title: const Text("Default backend"),
            subtitle: Text(kind == BackendKind.opencode
                ? "OpenCode (desktop)"
                : "mini-swe-agent"),
            trailing: Text(
              "opencode on desktop\nminiswe everywhere else",
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(),
          const _OpencodeSection(),
          const Divider(),
          const _DeleteAllChats(),
        ],
      ),
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

class _OpencodeSection extends ConsumerWidget {
  const _OpencodeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text("OpenCode", style: Theme.of(context).textTheme.titleMedium),
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
        const _EnvironmentEditor(),
      ],
    );
  }
}

/// The environment every `opencode serve` is started with: API keys, and
/// whatever else a provider reads out of it.
class _EnvironmentEditor extends ConsumerWidget {
  const _EnvironmentEditor();

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
    final theme = Theme.of(context);
    final env = ref.watch(appSettingsProvider).opencodeEnv;
    final names = env.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text("Environment", style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            "Passed to every opencode server. A running chat keeps the "
            "environment it started with.",
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
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
