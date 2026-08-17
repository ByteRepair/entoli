import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/chat_meta.dart";
import "../../domain/permission.dart";
import "../../providers.dart";
import "../sidebar/sidebar.dart";
import "../fonts.dart";
import "../widgets/destructive_button.dart";
import "../widgets/provider_model_selector.dart";
import "../widgets/resettable_field.dart";
import "../workspace/workspace_page.dart";

class ChatSettingsPage extends ConsumerStatefulWidget {
  const ChatSettingsPage({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends ConsumerState<ChatSettingsPage> {
  ChatMeta? _meta;

  /// The chat's own workspace, which needs the project its files are in before
  /// it can be named. Loaded with the meta rather than watched, since a chat
  /// does not move while its settings are open.
  String? _workspace;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(chatRepositoryProvider);
    // Together: neither answer needs the other, and both go to the store.
    final (meta, project) = await (
      repo.loadMeta(widget.chatId),
      repo.projectOf(widget.chatId),
    ).wait;
    final workspace =
        ref.read(appConfigProvider).workspaceDir(widget.chatId, project: project);
    if (mounted) {
      setState(() {
        _meta = meta;
        _workspace = workspace;
      });
    }
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
                _IdField(id: widget.chatId),
                const Divider(),
                WorkspaceTile(root: _workspace!, title: "Chat workspace"),
                const Divider(),
                _LlmField(
                  meta: _meta!,
                  onChanged: (m) => setState(() => _meta = m),
                ),
                const Divider(),
                _ApprovalField(
                  value: _meta!.approveMode,
                  onChanged: (v) => setState(() => _meta!.approveMode = v),
                ),
                const Divider(),
                _DeleteButton(chatId: widget.chatId),
              ],
            ),
    );
  }
}

class _IdField extends StatelessWidget {
  const _IdField({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return LabelledField(
      label: "Chat ID",
      child: Row(
        children: [
          Expanded(
            child: Text(
              id,
              style: const TextStyle(fontFamily: monoFamily),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: "Copy chat ID",
            onPressed: () {
              Clipboard.setData(ClipboardData(text: id));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Copied chat ID")),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DeleteButton extends ConsumerWidget {
  const _DeleteButton({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DestructiveButton(
      icon: Icons.delete,
      label: "Delete chat",
      confirmTitle: "Delete chat?",
      confirmMessage: "Delete this chat and all its files? This cannot be undone.",
      onConfirmed: () async {
        if (ref.read(selectedChatIdProvider) == chatId) {
          ref.read(selectedChatIdProvider.notifier).select(null);
        }
        await ref.read(chatRepositoryProvider).deleteChat(chatId);
        ref.invalidate(chatListProvider);
        if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      },
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
