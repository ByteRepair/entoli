import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/app_settings.dart"
    show ReasoningEffort, reasoningEffortLabels;
import "../../domain/builtin_project.dart";
import "../../app/settings/scope.dart";
import "../../app/settings/spec.dart" show WidgetReader;
import "../../domain/chat_meta.dart";
import "../../domain/settings/keys.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../providers.dart";
import "../selection.dart";
import "../../app/chat_controller.dart";
import "context_page.dart";
import "widgets/view_only_bar.dart" show MirrorStrip;
import "../widgets/destructive_button.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/settings_card.dart";
import "../widgets/temp_chat_ttl_field.dart";
import "../widgets/thinking_slider.dart";
import "../workspace/workspace_page.dart";
import "../widgets/page_bar.dart";

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
class NewChatSettingsPage extends ConsumerStatefulWidget {
  const NewChatSettingsPage({super.key, required this.initial, this.project});

  final ChatMeta initial;

  /// Which project's answers the TTL field names as what null inherits.
  final String? project;

  @override
  ConsumerState<NewChatSettingsPage> createState() =>
      _NewChatSettingsPageState();
}

class _NewChatSettingsPageState extends ConsumerState<NewChatSettingsPage> {
  /// A copy: the fields write in place, so backing out has to leave the
  /// screen behind this holding what it had.
  late final ChatMeta _meta = widget.initial.copy();

  @override
  Widget build(BuildContext context) {
    final scope = _chatScope(ref, _meta, widget.project, () => setState(() {}));
    return Scaffold(
      appBar: PageBar(
        title: "Chat settings",
        actions: [
          PageAction.confirm(onPressed: () => Navigator.of(context).pop(_meta)),
        ],
      ),
      body: ListView(
        children: [
          _LlmField(scope),
          _ThinkingField(scope),
          const Divider(),
          _ApprovalField(scope),
          const Divider(),
          _MemoryField(scope, project: widget.project),
          const Divider(),
          _TtlField(scope, project: widget.project),
        ],
      ),
    );
  }
}

/// The chat's settings as a scope over [meta], the project's above it: what
/// the fields read their own and inherited values from, and write to. A
/// draft, saved whole by the page.
ChatScope _chatScope(
  WidgetRef ref,
  ChatMeta meta,
  String? project,
  void Function() onChange,
) => ChatScope(
  meta.doc,
  projectScopeAt(WidgetReader(ref), ProjectAddress(project)),
  onChange: onChange,
);

/// Open [chatId]'s settings: its title bar and the app's Chat menu.
void openChatSettings(BuildContext context, String chatId) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => ChatSettingsPage(chatId: chatId)));

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
    final meta = _meta;
    final scope = meta == null
        ? null
        : _chatScope(ref, meta, _project, () => setState(() {}));
    final deviceName = ref.watch(
      remoteChatsProvider.select((chats) {
        for (final c in chats) {
          if (c.chatId == widget.chatId) return c.deviceName;
        }
        return null;
      }),
    );
    // A mirror whose home device is away is read, not written; it is read
    // again when the device comes back.
    final frozen = ref.watch(
      remoteChatsProvider.select(
        (chats) => chats.any((c) => c.chatId == widget.chatId && !c.online),
      ),
    );
    ref.listen(
      remoteChatsProvider.select(
        (chats) => chats.any((c) => c.chatId == widget.chatId && !c.online),
      ),
      (was, now) {
        if (was == true && !now) _load();
      },
    );
    return Scaffold(
      appBar: PageBar(
        title: "Chat settings",
        actions: [
          PageAction.confirm(
            onPressed: _saving || _meta == null || frozen ? null : _save,
          ),
        ],
      ),
      body: Column(
        children: [
          if (deviceName != null)
            frozen
                ? MirrorStrip.offline(deviceName: deviceName)
                : MirrorStrip.remote(deviceName: deviceName),
          Expanded(
            child: _meta == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      SettingsCardRow(
                        children: [
                          SettingsCard.copy(
                            icon: Icons.badge_outlined,
                            title: "Chat ID",
                            value: widget.chatId,
                            said: "Copied chat ID",
                          ),
                          if (_workspace != null)
                            WorkspaceTile(
                              root: _workspace!,
                              title: "Chat workspace",
                            ),
                          SettingsCard(
                            icon: Icons.data_usage,
                            title: "Context",
                            subtitle: "What fills the model's window",
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ContextPage(
                                  chatId: widget.chatId,
                                  project: _project,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      // The picker lists this device's providers, which the home
                      // device may not have.
                      if (!mirrored) ...[
                        const Divider(),
                        _LlmField(scope!),
                        _ThinkingField(scope),
                      ],
                      const Divider(),
                      _ApprovalField(scope!),
                      // What it inherits is the home device's project, which a
                      // mirror cannot read.
                      if (!mirrored) _SandboxField(scope),
                      const Divider(),
                      _MemoryField(scope, project: _project),
                      const Divider(),
                      if (_state?.pinned ?? false)
                        LabelledField(
                          label: "Temporary chat",
                          child: Text(
                            "This chat is pinned and cannot be temporary.",
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        )
                      else
                        _TtlField(scope, project: _project),
                      const Divider(),
                      if (!frozen) _DeleteButton(chatId: widget.chatId),
                    ],
                  ),
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
      confirmMessage:
          "Delete this chat and all its files? This cannot be undone.",
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

class _LlmField extends StatelessWidget {
  const _LlmField(this.scope);

  final ChatScope scope;

  @override
  Widget build(BuildContext context) => LabelledField(
    label: "LLM",
    child: ModelPicker(
      nullLabel: defaultOptionLabel,
      choice: (
        providerId: scope.own(SettingKeys.provider),
        modelId: scope.own(SettingKeys.model),
      ),
      inherited: (
        providerId: scope.root.resolve(SettingKeys.defaultProviderId),
        modelId: scope.root.resolve(SettingKeys.defaultModelId),
      ),
      onChanged: (choice) => scope.writeAll({
        SettingKeys.provider: choice.providerId,
        SettingKeys.model: choice.modelId,
      }),
    ),
  );
}

/// How long this chat's model thinks. Unset follows Settings > LLMs, which
/// the slider then shows and the reset restores, the way [InheritableSlider]
/// does.
class _ThinkingField extends StatelessWidget {
  const _ThinkingField(this.scope);

  final ChatScope scope;

  @override
  Widget build(BuildContext context) {
    final value = scope.own(SettingKeys.reasoningEffort);
    final inherited = scope.inherited(SettingKeys.reasoningEffort)!;
    void set(ReasoningEffort? v) => scope.write(SettingKeys.reasoningEffort, v);
    return LabelledField(
      label: "Thinking",
      child: ResettableField(
        onReset: () => set(null),
        resetLabel: "Settings > LLMs (${reasoningEffortLabels[inherited]})",
        child: ThinkingSlider(
          stops: reasoningEffortLabels,
          value: value ?? inherited,
          onChanged: set,
          help: value == null ? "Follows Settings > LLMs." : null,
        ),
      ),
    );
  }
}

/// Whether this chat's commands run under the sandbox, over the project's
/// answer and the default project's under it.
class _SandboxField extends StatelessWidget {
  const _SandboxField(this.scope);

  final ChatScope scope;

  @override
  Widget build(BuildContext context) {
    final value = scope.own(SettingKeys.sandbox);
    final inherited = scope.inherited(SettingKeys.sandbox) ?? true;
    return InheritableSwitch(
      title: "Sandbox",
      subtitle: (value ?? inherited)
          ? null
          : "Off: this chat's commands write wherever you can.",
      value: value,
      inherited: inherited,
      onChanged: (v) => scope.write(SettingKeys.sandbox, v),
    );
  }
}

/// Whether this chat keeps out of the memory subsystem. The on position
/// stores nothing — the chat follows whatever the project answers — and the
/// off one stores the off. A project that has no memory of its own takes the
/// subsystem away outright, and for that one the row says so and takes
/// nothing.
class _MemoryField extends StatelessWidget {
  const _MemoryField(this.scope, {required this.project});

  final ChatScope scope;
  final String? project;

  @override
  Widget build(BuildContext context) {
    final taken = builtinProjectOf(project)?.memory == MemoryPolicy.off;
    final value = scope.own(SettingKeys.memoryOff);
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text("Project memory"),
      subtitle: Text(
        taken
            ? "This project keeps no memories."
            : "Off, the agent reads, recalls and keeps no memories in this chat.",
      ),
      value: taken ? false : value != true,
      onChanged: taken
          ? null
          : (v) => scope.write(SettingKeys.memoryOff, v ? null : true),
    );
  }
}

/// How long this chat lives once its TTL is enabled, over the project's
/// answer and the app's.
class _TtlField extends StatelessWidget {
  const _TtlField(this.scope, {required this.project});

  final ChatScope scope;
  final String? project;

  @override
  Widget build(BuildContext context) => TempChatTtlField(
    value: scope.own(SettingKeys.tempChatTtl),
    onChanged: (v) => scope.write(SettingKeys.tempChatTtl, v),
    project: project,
  );
}

/// Whether this chat's commands wait for the user.
class _ApprovalField extends StatelessWidget {
  const _ApprovalField(this.scope);

  final ChatScope scope;

  @override
  Widget build(BuildContext context) {
    final value = scope.own(SettingKeys.approveMode);
    final inherited = scope.inherited(SettingKeys.approveMode)!;
    final noClassifier =
        scope.root.resolve(SettingKeys.classifierProviderId) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InheritableDropdown<ApproveMode>(
          label: "Running commands",
          value: value,
          inherited: approveModeLabels[inherited],
          options: approveModeLabels,
          disabled: {if (noClassifier) ApproveMode.auto},
          onChanged: (v) => scope.write(SettingKeys.approveMode, v),
        ),
        // The auto posture hides two decisions from the user it names: the
        // classifier can refuse without asking, and a run of escalations
        // falls back to asking. The label cannot carry that; this line can.
        if ((value ?? inherited) == ApproveMode.auto)
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
