import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/platform/default_backend.dart";
import "../../domain/app_settings.dart";
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
    final kind = defaultBackendKind();
    final settings = ref.watch(appSettingsProvider);
    final modelsAsync = ref.watch(availableModelsProvider);

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
          _OpencodeSection(settings: settings, modelsAsync: modelsAsync),
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
  const _OpencodeSection({required this.settings, required this.modelsAsync});

  final AppSettings settings;
  final AsyncValue<List<ModelOption>> modelsAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "OpenCode",
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        modelsAsync.when(
          data: (models) => _ModelSelector(models: models, settings: settings),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text("Loading models..."),
              ],
            ),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text("Failed to load models: $e"),
          ),
        ),
      ],
    );
  }
}

class _ModelSelector extends ConsumerWidget {
  const _ModelSelector({required this.models, required this.settings});

  final List<ModelOption> models;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ProviderModelSelector(
        models: models,
        choice: (
          providerId: settings.defaultProviderId,
          modelId: settings.defaultModelId,
        ),
        // Nothing above the app level to inherit from: Default means whatever
        // the backend picks.
        onChanged: (choice) {
          final notifier = ref.read(appSettingsProvider.notifier);
          final providerId = choice.providerId;
          final modelId = choice.modelId;
          if (providerId == null || modelId == null) {
            notifier.setDefaultProvider(providerId);
          } else {
            notifier.setDefaultModel(providerId, modelId);
          }
        },
      ),
    );
  }
}
