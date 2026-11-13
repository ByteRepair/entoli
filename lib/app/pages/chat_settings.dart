import "../../domain/builtin_project.dart";
import "../../domain/chat_meta.dart";
import "../../domain/models.dart";
import "../../domain/model_options.dart" show reasoningEffortLabels;
import "../../domain/settings/keys.dart";
import "../../providers.dart";
import "../chat_controller.dart";
import "../chat_edits.dart";
import "../settings/bind.dart";
import "../settings/controller.dart";
import "../settings/scope.dart";
import "../settings/spec.dart";
import "app_page.dart";
import "context.dart";
import "workspace.dart";

/// What the settings of a chat say, over a draft of its `meta.json`: the
/// model, how long it thinks, how its commands run, its memory and how long
/// it lives. Both a chat's page and a new chat's are made of these; each
/// says what it adds and how it saves.
abstract class ChatSettingsFields extends AppPage {
  /// The draft, null while it is read.
  ChatMeta? get meta;

  /// The project the chat is in, which its settings inherit from.
  String? get project;

  bool get mirrored => false;

  bool _dirty = false;

  ChatScope _scope(SettingReader reader) => ChatScope(
    meta!.doc,
    projectScopeAt(reader, ProjectAddress(project)),
    onChange: () {
      _dirty = true;
      changed();
    },
  );

  @override
  SettingConfirm? leaving(SettingReader reader) =>
      _dirty ? AppPage.discardChanges : null;

  /// The fields, in their sections.
  List<PageSection> fields(SettingReader reader, {bool pinned = false}) {
    final scope = _scope(reader);
    SettingContext at(String id, String title, UiHint hint) =>
        SettingContext(reader, scope, part(id, title, hint: hint));

    final memoryTaken = builtinProjectOf(project)?.memory == MemoryPolicy.off;
    final memoryOff = scope.own(SettingKeys.memoryOff) == true;
    return [
      // The picker lists this device's providers, which a mirror's home
      // device may not have.
      if (!mirrored)
        PageSection("model", "Model", [
          at("model", "LLM", UiHint.dropdown).model(
            (provider: SettingKeys.provider, model: SettingKeys.model),
            nullLabel: "Default",
            inherited: (
              providerId: scope.root.resolve(SettingKeys.defaultProviderId),
              modelId: scope.root.resolve(SettingKeys.defaultModelId),
            ),
          ),
          at(
            "thinking",
            "Thinking",
            UiHint.levels,
          ).choice(SettingKeys.reasoningEffort, [
            for (final MapEntry(key: effort, value: label)
                in reasoningEffortLabels.entries)
              SettingOption(effort, label),
          ]),
        ]),
      PageSection("agent", "Agent", [
        // The same controller the LLMs page builds, at this chat's level.
        shared(reader, scope, "approveMode"),
        // What it inherits is the home device's project, which a mirror
        // cannot read.
        if (!mirrored)
          at("sandbox", "Sandbox", UiHint.toggle).toggle(
            SettingKeys.sandbox,
            description: (scope.resolve(SettingKeys.sandbox) ?? true)
                ? null
                : "Off: this chat's commands write wherever you can.",
          ),
      ]),
      PageSection("memory", "Memory", [
        // On stores nothing — the chat follows the project — and off stores
        // the off. A project that keeps no memories takes it away outright.
        ToggleController(
          part("memory", "Project memory", hint: UiHint.toggle),
          value: memoryTaken ? false : !memoryOff,
          effective: memoryTaken ? false : !memoryOff,
          enabled: !memoryTaken,
          description: memoryTaken
              ? "This project keeps no memories."
              : "Off, the agent reads, recalls and keeps no memories in this "
                    "chat.",
          onSet: (on) async {
            await scope.write(SettingKeys.memoryOff, on ?? true ? null : true);
            return null;
          },
        ),
      ]),
      if (!pinned)
        PageSection("temporary", "Temporary chat", [_ttl(reader, scope)]),
    ];
  }

  SettingController _ttl(SettingReader reader, ChatScope scope) =>
      tempTtlChoice(
        "Delete after",
        value: scope.own(SettingKeys.tempChatTtl),
        // What `ChatRepository._resolveTempTtl` answers without the chat's own.
        inherited: inheritedTempTtl(
          project,
          own: reader.watch(projectSettingsProvider(project)).tempChatTtl,
          app: reader.watch(appSettingsProvider).tempChatTtl,
        ),
        onSet: (ttl) => scope.write(SettingKeys.tempChatTtl, ttl),
      );
}

/// [chatId]'s settings: what it is and where its files are, the fields,
/// and deleting it; saved whole by Save. A mirrored chat's are its home
/// device's, read again when the device comes back and not written while it
/// is away.
class ChatSettingsAppPage extends ChatSettingsFields {
  ChatSettingsAppPage(this.chatId);

  final String chatId;

  @override
  ChatMeta? meta;

  @override
  String? project;

  /// The state, loaded with the meta so the TTL anchor can be written again
  /// on Save without waiting for a turn; none where the chat has no
  /// `state.json`.
  ChatState? _state;
  String? _workspace;
  bool _saving = false;

  @override
  bool get mirrored => app.read(isMirroredChatProvider(chatId));

  @override
  void opened() => _load();

  @override
  String get address => "chat-settings/$chatId";

  Future<void> _load() async {
    final repo = app.read(chatRepositoryProvider);
    final (loaded, at) = await (
      repo.loadMeta(chatId),
      repo.projectOf(chatId),
    ).wait;
    ChatState? state;
    try {
      state = (await repo.openChat(chatId)).state;
    } catch (_) {
      state = null;
    }
    meta = loaded;
    project = at;
    _state = state;
    // A mirror's files are on its home device, with no path here to open.
    _workspace = mirrored
        ? null
        : app.read(appConfigProvider).workspaceDir(chatId, project: at);
    changed();
  }

  @override
  String title(SettingReader reader) => "Chat Settings";

  MirrorHome? _device(SettingReader reader) =>
      reader.watch(mirrorHomeProvider(chatId));

  @override
  List<PageSection> sections(SettingReader reader) {
    final device = _device(reader);
    final frozen = device != null && !device.online;
    if (meta == null) {
      return [notice("loading", "Reading the chat's settings…")];
    }
    final workspace = _workspace;
    return [
      if (device != null)
        deviceNotice("chat", device.name, online: device.online),
      PageSection("chat", "", [
        ActionController(
          part("id", "Chat ID", description: chatId),
          label: "Copy",
          run: () async => SettingNotice("Copied chat ID", copy: chatId),
        ),
        if (workspace != null)
          opener(
            "workspace",
            "Chat workspace",
            () => WorkspaceAppPage(root: workspace, owner: "Chat workspace"),
            glyph: SettingGlyph.folder,
          ),
        opener(
          "context",
          "Context",
          () => ContextAppPage(chatId, project: project),
          description: "What fills the model's window",
          glyph: SettingGlyph.info,
        ),
      ]),
      ...fields(reader, pinned: _state?.pinned ?? false),
      if (_state?.pinned ?? false)
        notice("pinned", "This chat is pinned and cannot be temporary."),
      if (!frozen)
        PageSection("delete", "", [
          ActionController(
            part("delete", "Delete Chat", hint: UiHint.button),
            destructive: true,
            confirm: () async => const SettingConfirm(
              title: "Delete chat?",
              message:
                  "Delete this chat and all its files? This cannot be undone.",
              confirmLabel: "Delete",
              destructive: true,
            ),
            run: () async {
              final state = _state;
              pages.closeAll();
              if (state != null) {
                await reader.read(chatEditsProvider).delete(state);
              }
              return null;
            },
          ),
        ]),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) {
    final device = _device(reader);
    final frozen = device != null && !device.online;
    return [
      ActionController(
        part("save", "Save"),
        enabled: meta != null && !_saving && !frozen,
        run: _save,
      ),
    ];
  }

  Future<SettingNotice?> _save() async {
    final meta = this.meta;
    if (meta == null) return null;
    _saving = true;
    changed();
    final repo = app.read(chatRepositoryProvider);
    await repo.saveMeta(chatId, meta);
    // Anchored again at once, so the countdown shows without waiting for a
    // turn; the write decides the anchor, so the bar is told what it wrote.
    if (_state case final state?) {
      final written = await repo.saveState(state, reanchor: true);
      // A mirror's controller hears it from the home device.
      if (!mirrored) {
        app.read(chatControllerProvider(chatId).notifier).applyState(written);
      }
    }
    app.invalidate(chatListProvider);
    _saving = false;
    pages.leave(this);
    return null;
  }
}

/// The settings a chat not made yet will run its first turn under, handed
/// back by Save for the new-chat screen to hold until the chat is made.
class NewChatSettingsAppPage extends ChatSettingsFields {
  NewChatSettingsAppPage({
    required ChatMeta initial,
    required this.project,
    required this.onSave,
  }) : meta = initial.copy();

  @override
  final ChatMeta meta;

  @override
  final String? project;

  final void Function(ChatMeta meta) onSave;

  @override
  String get address => "new-chat-settings";

  @override
  String title(SettingReader reader) => "Chat Settings";

  @override
  List<PageSection> sections(SettingReader reader) => fields(reader);

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    ActionController(
      part("save", "Save"),
      run: () async {
        onSave(meta);
        pages.leave(this);
        return null;
      },
    ),
  ];
}
