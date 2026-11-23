import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_settings_draft.dart";
import "package:entoli_chat/core/log.dart";
import "package:entoli_chat/domain/builtin_project.dart";
import "package:entoli_chat/domain/chat_meta.dart";
import "package:entoli_chat/domain/model_options.dart"
    show reasoningEffortLabels;
import "package:entoli_chat/domain/settings/keys.dart";
import "../../providers.dart";
import "../settings/llm_settings.dart" show ApproveModeChoice;
import "../settings/scoped.dart";
import "../settings/terminal_settings.dart" show SandboxSettings;
import "package:entoli_chat/ui/widgets/busy.dart";
import "../widgets/destructive_button.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart";
import "package:entoli_chat/ui/widgets/discard_guard.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/temp_chat_ttl_field.dart";
import "package:entoli_chat/ui/workspace/workspace_page.dart";
import "../../app/app_items.dart" show AppAction, onMirror;
import "../chat_actions.dart" show shareChat;
import "context_page.dart";
import "widgets/view_only_bar.dart" show DeviceNotice;

/// Open [chatId]'s settings: its title bar and the app's Chat menu.
Future<void> openChatSettings(BuildContext context, String chatId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatSettingsPage(chatId: chatId)),
    );

/// The settings a chat not made yet will run under, [onSave] handed them on
/// Save; backed out of, nothing is.
Future<void> openNewChatSettings(
  BuildContext context, {
  required ChatMeta initial,
  required String? project,
  required void Function(ChatMeta meta) onSave,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        NewChatSettingsPage(initial: initial, project: project, onSave: onSave),
  ),
);

/// [chatId]'s settings: what it is and where its files are, the fields, and
/// deleting it; saved whole by Save. A mirrored chat's are its home
/// device's, read again when the device comes back and not written while it
/// is away.
class ChatSettingsPage extends ConsumerStatefulWidget {
  const ChatSettingsPage({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends ConsumerState<ChatSettingsPage> {
  ChatSettingsDraft? _draft;
  Object? _failed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _draft?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final draft = await ref
          .read(chatSettingsEditorProvider)
          .load(widget.chatId);
      if (!mounted) return draft.dispose();
      _draft?.dispose();
      setState(() {
        _draft = draft..addListener(_redraw);
        _failed = null;
      });
    } catch (e) {
      logFailure("chat", "could not read ${widget.chatId}'s settings", e);
      if (mounted) setState(() => _failed = e);
    }
  }

  void _redraw() => setState(() {});

  Future<void> _save(ChatSettingsDraft draft) async {
    setState(() => _saving = true);
    try {
      await guarded(context, () async {
        await ref.read(chatSettingsEditorProvider).save(draft);
        if (mounted) Navigator.of(context).pop();
      });
    } finally {
      // A failed write leaves the page up to try again.
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The pages go first, so nothing is left open on a chat that is gone.
  Future<void> _delete() async {
    final editor = ref.read(chatSettingsEditorProvider);
    Navigator.of(context).popUntil((route) => route.isFirst);
    await guarded(context, () => editor.delete(widget.chatId));
  }

  @override
  Widget build(BuildContext context) {
    final chatId = widget.chatId;
    final device = ref.watch(mirrorHomeProvider(chatId));
    final frozen = device != null && !device.online;
    ref.listen(mirrorHomeProvider(chatId).select((home) => home?.online), (
      was,
      now,
    ) {
      if (was == false && now == true) _load();
    });
    final draft = _draft;
    return DiscardGuard(
      edited: () => _draft?.edited ?? false,
      child: Scaffold(
        appBar: PageBar(
          title: "Chat Settings",
          actions: [
            PageAction.confirm(
              onPressed: draft == null || _saving || frozen
                  ? null
                  : () => _save(draft),
            ),
          ],
        ),
        body: draft == null
            ? Center(
                child: _failed == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text("Could not read the settings: $_failed"),
                      ),
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (device != null)
                    DeviceNotice(
                      what: "chat",
                      deviceName: device.name,
                      online: device.online,
                    ),
                  ListTile(
                    title: const Text("Chat ID"),
                    subtitle: Text(chatId),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: "Copy",
                      onPressed: () => copyToClipboard(
                        context,
                        chatId,
                        said: "Copied chat ID",
                      ),
                    ),
                  ),
                  if (draft.workspace case final workspace?)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text("Chat workspace"),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openWorkspace(
                        context,
                        root: workspace,
                        title: "Chat workspace",
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text("Context"),
                    subtitle: const Text("What fills the model's window"),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openContext(
                      context,
                      chatId: chatId,
                      project: draft.project,
                    ),
                  ),
                  if (device == null ||
                      onMirror(AppAction.shareChat).isAvailable)
                    Builder(
                      builder: (tile) => ListTile(
                        leading: const Icon(Icons.ios_share),
                        title: const Text("Share"),
                        subtitle: const Text("A link anyone can read it from"),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => catchAndSay(context, () async {
                          final state = await ref
                              .read(chatRepositoryProvider)
                              .loadState(chatId);
                          if (state == null || !tile.mounted) return;
                          await shareChat(tile, ref, state);
                        }),
                      ),
                    ),
                  const Divider(),
                  ChatSettingsFields(
                    draft: draft,
                    mirrored: ref.watch(isMirroredChatProvider(chatId)),
                  ),
                  if (!frozen) ...[
                    const Divider(),
                    DestructiveButton(
                      icon: Icons.delete,
                      label: "Delete Chat",
                      confirmTitle: "Delete chat?",
                      confirmMessage:
                          "Delete this chat and all its files? This cannot "
                          "be undone.",
                      onConfirmed: _delete,
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// The settings a chat not made yet will run its first turn under, handed
/// back by Save for the new-chat screen to hold until the chat is made.
class NewChatSettingsPage extends StatefulWidget {
  const NewChatSettingsPage({
    super.key,
    required this.initial,
    required this.project,
    required this.onSave,
  });

  final ChatMeta initial;
  final String? project;
  final void Function(ChatMeta meta) onSave;

  @override
  State<NewChatSettingsPage> createState() => _NewChatSettingsPageState();
}

class _NewChatSettingsPageState extends State<NewChatSettingsPage> {
  late final _draft = ChatSettingsDraft.newChat(
    widget.initial,
    project: widget.project,
  )..addListener(() => setState(() {}));

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    edited: () => _draft.edited,
    child: Scaffold(
      appBar: PageBar(
        title: "Chat Settings",
        actions: [
          PageAction.confirm(
            onPressed: () {
              widget.onSave(_draft.meta);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [ChatSettingsFields(draft: _draft)],
      ),
    ),
  );
}

/// What both a chat's page and a new chat's edit: the model, how long it
/// thinks, how its commands run, its memory and how long it lives.
class ChatSettingsFields extends ConsumerWidget {
  const ChatSettingsFields({
    super.key,
    required this.draft,
    this.mirrored = false,
  });

  final ChatSettingsDraft draft;

  /// A mirror's providers and project are its home device's, so the rows
  /// that pick from them are left off.
  final bool mirrored;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final at = draft.at;
    final scope = scopeOf(ref, at);
    final taken = builtinProjectOf(draft.project)?.memory == MemoryPolicy.off;
    final memoryOff = scope.own(SettingKeys.memoryOff) == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mirrored) ...[
          const SectionHeader("Model"),
          ScopedModel(
            keys: (provider: SettingKeys.provider, model: SettingKeys.model),
            at: at,
            title: "LLM",
            nullLabel: defaultOptionLabel,
            inherited: (
              providerId: scope.root.resolve(SettingKeys.defaultProviderId),
              modelId: scope.root.resolve(SettingKeys.defaultModelId),
            ),
          ),
          ScopedLevels(
            setting: SettingKeys.reasoningEffort,
            at: at,
            title: "Thinking",
            stops: reasoningEffortLabels,
          ),
          const Divider(),
        ],
        const SectionHeader("Agent"),
        ApproveModeChoice(at: at),
        if (!mirrored) SandboxSettings(at: at),
        const Divider(),
        const SectionHeader("Memory"),
        // On stores nothing, the chat following the project, and off stores
        // the off.
        SwitchListTile(
          title: const Text("Project memory"),
          subtitle: Text(
            taken
                ? "This project keeps no memories."
                : "Off, the agent reads, recalls and keeps no memories in "
                      "this chat.",
          ),
          value: !taken && !memoryOff,
          onChanged: taken
              ? null
              : (on) => scope.write(SettingKeys.memoryOff, on ? null : true),
        ),
        const Divider(),
        const SectionHeader("Temporary chat"),
        if (draft.pinned)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: mutedParagraph(
              context,
              "This chat is pinned and cannot be temporary.",
            ),
          )
        else
          TempChatTtlField(
            label: "Delete after",
            value: scope.own(SettingKeys.tempChatTtl),
            project: draft.project,
            onChanged: (ttl) => scope.write(SettingKeys.tempChatTtl, ttl),
          ),
      ],
    );
  }
}
