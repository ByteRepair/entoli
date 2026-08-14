import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../providers.dart";
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

class _LlmDropdowns extends StatefulWidget {
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
  State<_LlmDropdowns> createState() => _LlmDropdownsState();
}

class _LlmDropdownsState extends State<_LlmDropdowns> {
  /// null means [defaultOptionLabel]: the chat inherits the app-level default.
  String? _provider;

  @override
  void initState() {
    super.initState();
    final ids = widget.models.map((m) => m.providerId).toSet();
    if (ids.contains(widget.meta.provider)) {
      _provider = widget.meta.provider;
      return;
    }
    // meta.json may name a model without its provider; recover it from the
    // model so the saved choice still shows up.
    final owning = widget.models.where((m) => m.modelId == widget.meta.model);
    if (owning.isNotEmpty) _provider = owning.first.providerId;
  }

  void _selectProvider(String? provider) {
    setState(() => _provider = provider);
    final keepsModel = widget.models
        .any((m) => m.providerId == provider && m.modelId == widget.meta.model);
    widget.onChanged(widget.meta
      ..provider = provider
      ..model = keepsModel ? widget.meta.model : null);
  }

  /// Pinning a model pins the provider it came from with it.
  void _selectModel(String? modelId, String listedUnder) {
    if (modelId == null) {
      widget.onChanged(widget.meta..model = null);
      return;
    }
    setState(() => _provider = listedUnder);
    widget.onChanged(widget.meta
      ..model = modelId
      ..provider = listedUnder);
  }

  String? _labelOf(String? modelId) {
    final match = widget.models.where((m) => m.modelId == modelId);
    return match.isEmpty ? modelId : (match.first.label ?? match.first.modelId);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.models.isEmpty) {
      return const Text("No models available. Start a chat to load models.");
    }

    final providerIds = widget.models.map((m) => m.providerId).toSet().toList()..sort();

    // On Default, list the models of whatever provider the chat will actually
    // use, so the list is never empty.
    final listedProvider =
        _provider ?? widget.defaults.defaultProviderId ?? providerIds.first;
    final modelsForProvider = widget.models
        .where((m) => m.providerId == listedProvider)
        .toList()
      ..sort((a, b) {
        final la = (a.label ?? a.modelId).toLowerCase();
        final lb = (b.label ?? b.modelId).toLowerCase();
        return la.compareTo(lb);
      });

    final currentModel =
        modelsForProvider.any((m) => m.modelId == widget.meta.model) ? widget.meta.model : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResettableField(
          isDefault: _provider == null,
          onReset: () => _selectProvider(null),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Provider",
              border: const OutlineInputBorder(),
              helperText: _provider == null
                  ? "Using ${widget.defaults.defaultProviderId ?? "the backend default"}"
                  : null,
            ),
            initialValue: _provider,
            items: [
              defaultMenuItem(),
              ...providerIds.map((p) => DropdownMenuItem<String?>(value: p, child: Text(p))),
            ],
            onChanged: _selectProvider,
          ),
        ),
        const SizedBox(height: 12),
        ResettableField(
          isDefault: widget.meta.model == null,
          onReset: () => _selectModel(null, listedProvider),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Model",
              border: const OutlineInputBorder(),
              helperText: widget.meta.model == null
                  ? "Using ${_labelOf(widget.defaults.defaultModelId) ?? "the backend default"}"
                  : null,
            ),
            initialValue: currentModel,
            items: [
              defaultMenuItem(),
              ...modelsForProvider.map((m) {
                return DropdownMenuItem<String?>(value: m.modelId, child: Text(m.label ?? m.modelId));
              }),
            ],
            onChanged: (v) => _selectModel(v, listedProvider),
          ),
        ),
      ],
    );
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