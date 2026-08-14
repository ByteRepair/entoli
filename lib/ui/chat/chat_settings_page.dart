import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../widgets/provider_model_selector.dart";
import "../widgets/resettable_field.dart";

const _reasoningEfforts = ["minimal", "low", "medium", "high"];

class ChatSettingsPage extends ConsumerStatefulWidget {
  const ChatSettingsPage({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends ConsumerState<ChatSettingsPage> {
  ChatMeta? _meta;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(chatRepositoryProvider);
    final meta = await repo.loadMeta(widget.chatId);
    if (mounted) setState(() => _meta = meta);
  }

  Future<void> _save() async {
    if (_meta == null) return;
    setState(() => _saving = true);
    final repo = ref.read(chatRepositoryProvider);
    await repo.saveMeta(widget.chatId, _meta!);
    if (mounted) setState(() => _saving = false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final modelsAsync = ref.watch(availableModelsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Chat settings"),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saving || _meta == null ? null : _save,
            tooltip: "Save",
          ),
        ],
      ),
      body: _meta == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _LlmField(
                  meta: _meta!,
                  modelsAsync: modelsAsync,
                  onChanged: (m) => setState(() => _meta = m),
                ),
                const Divider(),
                _TemperatureField(
                  value: _meta!.temperature,
                  onChanged: (v) => setState(() => _meta!.temperature = v),
                ),
                const Divider(),
                _ReasoningEffortField(
                  value: _meta!.reasoningEffort,
                  onChanged: (v) => setState(() => _meta!.reasoningEffort = v),
                ),
              ],
            ),
    );
  }
}

class _LlmField extends ConsumerWidget {
  const _LlmField({required this.meta, required this.modelsAsync, required this.onChanged});

  final ChatMeta meta;
  final AsyncValue<List<ModelOption>> modelsAsync;
  final ValueChanged<ChatMeta> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaults = ref.watch(appSettingsProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("LLM", style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          modelsAsync.when(
            data: (models) => _LlmDropdowns(
              models: models,
              meta: meta,
              defaults: defaults,
              onChanged: onChanged,
            ),
            loading: () => const Row(
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
            error: (e, _) => Text("Failed to load models: $e"),
          ),
        ],
      ),
    );
  }
}

class _LlmDropdowns extends StatelessWidget {
  const _LlmDropdowns({
    required this.models,
    required this.meta,
    required this.defaults,
    required this.onChanged,
  });

  final List<ModelOption> models;
  final ChatMeta meta;
  final AppSettings defaults;
  final ValueChanged<ChatMeta> onChanged;

  @override
  Widget build(BuildContext context) {
    return ProviderModelSelector(
      models: models,
      choice: (providerId: _pinnedProvider, modelId: meta.model),
      inherited: (
        providerId: defaults.defaultProviderId,
        modelId: defaults.defaultModelId,
      ),
      onChanged: (choice) => onChanged(meta
        ..provider = choice.providerId
        ..model = choice.modelId),
    );
  }

  /// meta.json may name a model without its provider; recover it from the
  /// model so the saved choice still shows up.
  String? get _pinnedProvider {
    if (meta.provider != null) return meta.provider;
    final owning = models.where((m) => m.modelId == meta.model);
    return owning.isEmpty ? null : owning.first.providerId;
  }
}

class _TemperatureField extends StatelessWidget {
  const _TemperatureField({required this.value, required this.onChanged});

  final double? value;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value ?? 1.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text("Temperature", style: TextStyle(fontSize: 12)),
              const Spacer(),
              Text(
                value == null ? defaultOptionLabel : v.toStringAsFixed(2),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          ResettableField(
            isDefault: value == null,
            onReset: () => onChanged(null),
            child: Slider(
              min: 0,
              max: 2,
              divisions: 20,
              value: v,
              label: v.toStringAsFixed(2),
              onChanged: (nv) => onChanged(nv),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasoningEffortField extends StatelessWidget {
  const _ReasoningEffortField({required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Reasoning effort", style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          ResettableField(
            isDefault: value == null,
            onReset: () => onChanged(null),
            child: DropdownButton<String?>(
              isExpanded: true,
              value: value,
              items: [
                defaultMenuItem(),
                ..._reasoningEfforts.map((e) {
                  return DropdownMenuItem<String?>(value: e, child: Text(e));
                }),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}