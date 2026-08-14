import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/platform/default_backend.dart";
import "../../domain/app_settings.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../widgets/resettable_field.dart";

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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete all chats?"),
        content: Text(
          count == 0
              ? "There are no chats to delete."
              : "This permanently removes $count ${count == 1 ? "chat" : "chats"}, "
                  "including their workspaces. It cannot be undone.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          if (count > 0)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text("Delete all"),
            ),
        ],
      ),
    );
    if (confirmed != true) return;

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

class _ModelSelector extends ConsumerStatefulWidget {
  const _ModelSelector({required this.models, required this.settings});

  final List<ModelOption> models;
  final AppSettings settings;

  @override
  ConsumerState<_ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends ConsumerState<_ModelSelector> {
  String? _selectedProvider;

  @override
  void initState() {
    super.initState();
    final ids = widget.models.map((m) => m.providerId).toSet();
    _selectedProvider = ids.contains(widget.settings.defaultProviderId)
        ? widget.settings.defaultProviderId
        : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.models.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Text("No models available. Start a chat to load models."),
      );
    }

    final providerIds = widget.models.map((m) => m.providerId).toSet().toList()..sort();

    final effectiveProvider = _selectedProvider ?? providerIds.first;
    final modelsForProvider = widget.models
        .where((m) => m.providerId == effectiveProvider)
        .toList()
      ..sort((a, b) {
        final la = (a.label ?? a.modelId).toLowerCase();
        final lb = (b.label ?? b.modelId).toLowerCase();
        return la.compareTo(lb);
      });

    // A stale settings.json can name a model the backend no longer offers;
    // feeding that to the dropdown trips its "exactly one item" assert.
    final savedModelId = widget.settings.defaultProviderId == effectiveProvider
        ? widget.settings.defaultModelId
        : null;
    final currentModelId =
        modelsForProvider.any((m) => m.modelId == savedModelId) ? savedModelId : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ResettableField(
            isDefault: _selectedProvider == null,
            onReset: () {
              setState(() => _selectedProvider = null);
              ref.read(appSettingsProvider.notifier).clearDefaultModel();
            },
            child: DropdownButtonFormField<String?>(
              decoration: const InputDecoration(
                labelText: "Provider",
                border: OutlineInputBorder(),
              ),
              initialValue: _selectedProvider,
              items: [
                defaultMenuItem(),
                ...providerIds.map((p) {
                  return DropdownMenuItem<String?>(value: p, child: Text(p));
                }),
              ],
              onChanged: (value) => setState(() => _selectedProvider = value),
            ),
          ),
          const SizedBox(height: 12),
          ResettableField(
            isDefault: currentModelId == null,
            onReset: () => ref.read(appSettingsProvider.notifier).clearDefaultModel(),
            child: DropdownButtonFormField<String?>(
              decoration: const InputDecoration(
                labelText: "Model",
                border: OutlineInputBorder(),
              ),
              initialValue: currentModelId,
              items: [
                defaultMenuItem(),
                ...modelsForProvider.map((m) {
                  return DropdownMenuItem<String?>(
                    value: m.modelId,
                    child: Text(m.label ?? m.modelId),
                  );
                }),
              ],
              onChanged: (value) async {
                if (value == null) {
                  await ref.read(appSettingsProvider.notifier).clearDefaultModel();
                } else {
                  await ref
                      .read(appSettingsProvider.notifier)
                      .setDefaultModel(effectiveProvider, value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}