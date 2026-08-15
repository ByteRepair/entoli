import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_meta.dart";
import "../../domain/permission.dart";
import "../../providers.dart";
import "../widgets/provider_model_selector.dart";
import "../widgets/resettable_field.dart";

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
    final meta = await ref.read(chatRepositoryProvider).loadMeta(widget.chatId);
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
                  onChanged: (m) => setState(() => _meta = m),
                ),
                const Divider(),
                _ApprovalField(
                  value: _meta!.approveMode,
                  onChanged: (v) => setState(() => _meta!.approveMode = v),
                ),
              ],
            ),
    );
  }
}

class _LlmField extends ConsumerWidget {
  const _LlmField({required this.meta, required this.onChanged});

  final ChatMeta meta;
  final ValueChanged<ChatMeta> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaults = ref.watch(appSettingsProvider);
    return LabelledField(
      label: "LLM",
      child: ModelPicker(
        choice: (providerId: meta.provider, modelId: meta.model),
        inherited: (
          providerId: defaults.defaultProviderId,
          modelId: defaults.defaultModelId,
        ),
        onChanged: (choice) => onChanged(meta
          ..provider = choice.providerId
          ..model = choice.modelId),
      ),
    );
  }
}

/// Whether this chat's commands wait for the user.
class _ApprovalField extends ConsumerWidget {
  const _ApprovalField({required this.value, required this.onChanged});

  final ApproveMode? value;
  final ValueChanged<ApproveMode?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final noClassifier = settings.classifierProviderId == null;
    return InheritableDropdown<ApproveMode>(
      label: "Running commands",
      value: value,
      inherited: approveModeLabels[settings.approveMode],
      options: approveModeLabels,
      disabled: {if (noClassifier) ApproveMode.auto},
      onChanged: onChanged,
    );
  }
}
