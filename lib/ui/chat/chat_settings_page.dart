import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/builtin_project.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../providers.dart";
import "../selection.dart";
import "chat_controller.dart";
import "context_page.dart";
import "widgets/view_only_bar.dart" show MirrorStrip;
import "../widgets/destructive_button.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/settings_card.dart";
import "../widgets/temp_chat_ttl_field.dart";
import "../workspace/workspace_page.dart";

/// The settings a chat that has not been made yet will run its first turn
/// under, popped back as a [ChatMeta] for the new-chat screen to hold until it
/// creates one — see "Nothing selected is a new chat". Dismissed without Save
/// it pops nothing, and the screen keeps what it had.
///
/// A page of its own rather than a mode of [ChatSettingsPage], because the
/// three fields here are all it can honestly show: an id, a workspace and a
/// Delete button all answer for a chat on disk, and there is none. Folded in,
/// they were five null checks and two `!`s through a page whose ordinary
/// subject exists — the same shape this change took out of the repository.
class NewChatSettingsPage extends StatefulWidget {
  const NewChatSettingsPage({super.key, required this.initial, this.project});

  final ChatMeta initial;

  /// Which project's answers the TTL field names as what null inherits.
  final String? project;

  @override
  State<NewChatSettingsPage> createState() => _NewChatSettingsPageState();
}

class _NewChatSettingsPageState extends State<NewChatSettingsPage> {
  /// A copy: the fields write in place, so backing out has to leave the
  /// screen behind this holding what it had.
  late final ChatMeta _meta = widget.initial.copy();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text("Chat settings"),
          actions: [
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: "Save",
              onPressed: () => Navigator.of(context).pop(_meta),
            ),
          ],
        ),
        body: ListView(
          children: [
            // `_LlmField` writes the pair onto the meta it was given and hands
            // back that same object, so there is nothing to take from it.
            _LlmField(meta: _meta, onChanged: (_) => setState(() {})),
            const Divider(),
            _ApprovalField(
              value: _meta.approveMode,
              onChanged: (v) => setState(() => _meta.approveMode = v),
            ),
            const Divider(),
            _MemoryField(
              value: _meta.memoryOff,
              project: widget.project,
              onChanged: (v) => setState(() => _meta.memoryOff = v),
            ),
            const Divider(),
            TempChatTtlField(
              value: _meta.tempChatTtl,
              onChanged: (v) => setState(() => _meta.tempChatTtl = v),
              project: widget.project,
            ),
          ],
        ),
      );
}

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

  /// The project the chat's files are in, so the TTL field can name what null
  /// resolves to.
  String? _project;

  /// The chat's state, loaded with the meta so the TTL anchor can be
  /// re-written in [_save] without waiting for a turn.
  ChatState? _state;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final chatId = widget.chatId;
    final repo = ref.read(chatRepositoryProvider);
    // Together: neither answer needs the other, and all go to the store.
    final (meta, project) = await (
      repo.loadMeta(chatId),
      repo.projectOf(chatId),
    ).wait;
    // The state is needed only to re-anchor the TTL in [_save]. A chat with no
    // `state.json` has none, and the re-anchor is skipped — the next turn's
    // `saveState` will anchor it.
    ChatState? state;
    try {
      state = (await repo.openChat(chatId)).state;
    } catch (_) {
      state = null;
    }
    // A mirror's files are on its home device, with no path here to open.
    final workspace = ref.read(isMirroredChatProvider(chatId))
        ? null
        : ref.read(appConfigProvider).workspaceDir(chatId, project: project);
    if (mounted) {
      setState(() {
        _meta = meta;
        _workspace = workspace;
        _project = project;
        _state = state;
      });
    }
  }

  Future<void> _save() async {
    if (_meta == null) return;
    final chatId = widget.chatId;
    setState(() => _saving = true);
    final repo = ref.read(chatRepositoryProvider);
    await repo.saveMeta(chatId, _meta!);
    // Re-anchor immediately so the sidebar hourglass and title-bar countdown
    // appear without waiting for a turn. `reanchor: true` so flipping the
    // chat's override on anchors to now, and off clears. The anchor is decided
    // by the write rather than by what was passed in, so the bar is told what
    // was written.
    if (_state != null) {
      final written = await repo.saveState(_state!, reanchor: true);
      // A mirror's controller hears it from the home device.
      if (!ref.read(isMirroredChatProvider(chatId))) {
        ref.read(chatControllerProvider(chatId).notifier).applyState(written);
      }
    }
    ref.invalidate(chatListProvider);
    if (mounted) setState(() => _saving = false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mirrored = ref.watch(isMirroredChatProvider(widget.chatId));
    final deviceName = ref.watch(remoteChatsProvider.select((chats) {
      for (final c in chats) {
        if (c.chatId == widget.chatId) return c.deviceName;
      }
      return null;
    }));
    // A mirror whose home device is away is read, not written; it is read
    // again when the device comes back.
    final frozen = ref.watch(remoteChatsProvider.select(
        (chats) => chats.any((c) => c.chatId == widget.chatId && !c.online)));
    ref.listen(remoteChatsProvider.select(
        (chats) => chats.any((c) => c.chatId == widget.chatId && !c.online)),
        (was, now) {
      if (was == true && !now) _load();
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text("Chat settings"),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saving || _meta == null || frozen ? null : _save,
            tooltip: "Save",
          ),
        ],
      ),
      body: Column(children: [
        if (deviceName != null)
          frozen
              ? MirrorStrip.offline(deviceName: deviceName)
              : MirrorStrip.remote(deviceName: deviceName),
        Expanded(child: _meta == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SettingsCardRow(children: [
                  SettingsCard.copy(
                    icon: Icons.badge_outlined,
                    title: "Chat ID",
                    value: widget.chatId,
                    said: "Copied chat ID",
                  ),
                  if (_workspace != null)
                    WorkspaceTile(root: _workspace!, title: "Chat workspace"),
                  SettingsCard(
                    icon: Icons.data_usage,
                    title: "Context",
                    subtitle: "What fills the model's window",
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ContextPage(chatId: widget.chatId, project: _project))),
                  ),
                ]),
                // The picker lists this device's providers, which the home
                // device may not have.
                if (!mirrored) ...[
                  const Divider(),
                  _LlmField(
                    meta: _meta!,
                    onChanged: (m) => setState(() => _meta = m),
                  ),
                ],
                const Divider(),
                _ApprovalField(
                  value: _meta!.approveMode,
                  onChanged: (v) => setState(() => _meta!.approveMode = v),
                ),
                // What it inherits is the home device's project, which a
                // mirror cannot read.
                if (!mirrored)
                  _SandboxField(
                    value: _meta!.sandbox,
                    project: _project,
                    onChanged: (v) => setState(() => _meta!.sandbox = v),
                  ),
                const Divider(),
                _MemoryField(
                  value: _meta!.memoryOff,
                  project: _project,
                  onChanged: (v) => setState(() => _meta!.memoryOff = v),
                ),
                const Divider(),
                if (_state?.pinned ?? false)
                  LabelledField(
                    label: "Temporary chat",
                    child: Text(
                      "This chat is pinned and cannot be temporary.",
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  )
                else
                  TempChatTtlField(
                    value: _meta!.tempChatTtl,
                    onChanged: (v) => setState(() => _meta!.tempChatTtl = v),
                    project: _project,
                  ),
                const Divider(),
                if (!frozen) _DeleteButton(chatId: widget.chatId),
              ],
            )),
      ]),
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
        nullLabel: defaultOptionLabel,
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

/// Whether this chat keeps out of the memory subsystem. The on position
/// stores null — the chat follows whatever the project answers — and the off
/// one stores the off. A project that has no memory of its own takes the
/// subsystem away outright, and for that one the row says so and takes
/// nothing.
class _SandboxField extends ConsumerWidget {
  const _SandboxField(
      {required this.value, required this.project, required this.onChanged});

  final bool? value;
  final String? project;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inherited = ref.watch(projectSettingsProvider(project)).sandbox ??
        ref.watch(projectSettingsProvider(null)).sandbox ??
        true;
    return InheritableSwitch(
      title: "Sandbox commands (Landlock)",
      subtitle: (value ?? inherited)
          ? null
          : "Off: this chat's commands write wherever you can.",
      value: value,
      inherited: inherited,
      onChanged: onChanged,
    );
  }
}

class _MemoryField extends StatelessWidget {
  const _MemoryField(
      {required this.value, required this.project, required this.onChanged});

  final bool? value;
  final String? project;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final taken = builtinProjectOf(project)?.memory == MemoryPolicy.off;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text("Project memory"),
      subtitle: Text(taken
          ? "This project keeps no memories."
          : "Off, the agent reads, recalls and keeps no memories in this chat."),
      value: taken ? false : value != true,
      onChanged: taken ? null : (v) => onChanged(v ? null : true),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InheritableDropdown<ApproveMode>(
          label: "Running commands",
          value: value,
          inherited: approveModeLabels[settings.approveMode],
          options: approveModeLabels,
          disabled: {if (noClassifier) ApproveMode.auto},
          onChanged: onChanged,
        ),
        // The auto posture hides two decisions from the user it names: the
        // classifier can refuse without asking, and a run of escalations
        // falls back to asking. The label cannot carry that; this line can.
        if ((value ?? settings.approveMode) == ApproveMode.auto)
          const Padding(
            padding: EdgeInsets.only(left: 16, top: 2),
            child: Text(
              "The classifier can also refuse a command outright, without "
              "asking you. Reads and writes inside the chat's workspace "
              "pass; anything past it waits for you. After several "
              "escalations in a turn, the rest of the turn asks.",
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }
}
