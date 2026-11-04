import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "../chat/widgets/composer.dart";
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart";
import "../chat/widgets/composer_logic.dart";
import "../widgets/agent_picture.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "shell_outbox.dart";
import "shell_slots.dart";

/// A composer menu as the contract names it, and back.
CompletionKind completionOf(ComposerTrigger trigger) => switch (trigger) {
  ComposerTrigger.skill => CompletionKind.skill,
  ComposerTrigger.agent => CompletionKind.agent,
};

ComposerTrigger triggerOf(CompletionKind kind) => switch (kind) {
  CompletionKind.skill => ComposerTrigger.skill,
  CompletionKind.agent => ComposerTrigger.agent,
};

/// An agent's face in the native `@` menu, in points: `ComposerView.swift`'s
/// `menuFace`, which draws it at that size.
const _menuFace = 22.0;

/// The composer, drawn by the native shell: configured by a [Composer] that
/// is never mounted, and its rules through the same [ComposerLogic], with no
/// Flutter of its own on screen. It sends the shell what to draw and runs what
/// the user did there; the text is Dart's, in the config's controller, as it
/// is for [Composer].
class ShellComposer extends ConsumerStatefulWidget {
  const ShellComposer({super.key, required this.config});

  final Composer config;

  @override
  ConsumerState<ShellComposer> createState() => ShellComposerState();
}

class ShellComposerState extends ConsumerState<ShellComposer>
    implements ComposerHandle, ComposerIntents {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);
  late final ComposerLogic _logic = ComposerLogic(widget.config.controller);
  late final Listenable _shape = Listenable.merge([
    _logic,
    _logic.canSend,
    _logic.queues,
    widget.config.controller,
  ]);

  /// The value the shell is reporting, so the change it makes is not sent
  /// back to it — which mid-composition would undo the input method's marked
  /// text. Held only while that change lands: a later one of Dart's own to
  /// the same value has to reach the shell.
  TextEditingValue? _reported;

  /// The completion token a press of Escape closed the menu on; it stays
  /// closed until the caret is in another.
  CompletionToken? _dismissed;

  /// The menu as last drawn, which a `pick` names a row of.
  List<CompletionOption> _matches = const [];
  CompletionToken? _token;

  @override
  void initState() {
    super.initState();
    _slots.composer.claim(this);
    _configure();
    widget.config.controller.addListener(_pushValue);
    _pushValue();
  }

  @override
  void didUpdateWidget(ShellComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.controller != widget.config.controller) {
      oldWidget.config.controller.removeListener(_pushValue);
      widget.config.controller.addListener(_pushValue);
      _logic.controller = widget.config.controller;
      _pushValue();
    }
    _configure();
  }

  @override
  void dispose() {
    widget.config.controller.removeListener(_pushValue);
    if (_slots.composer.leave(this)) {
      _outbox.composer(ComposerSnapshot(present: false));
    }
    _logic.dispose();
    super.dispose();
  }

  void _configure() => _logic.configure(
    agentSpeaking: widget.config.agentSpeaking,
    onSend: widget.config.onSend,
    onQueue: widget.config.onQueue,
    steers: widget.config.steers,
  );

  @override
  void restore(Draft said) => _logic.restore(said);

  /// Add [embed] and put the caret in the field, as [Composer.embed] does.
  @override
  void embed(ComposerEmbed embed) {
    widget.config.controller.append(embed);
    _outbox.focusComposer();
  }

  void _pushValue() {
    final value = widget.config.controller.value;
    if (value == _reported) return;
    _outbox.composerValue(_valueOf(value));
  }

  static ComposerValueSnapshot _valueOf(TextEditingValue value) {
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    return ComposerValueSnapshot(
      text: value.text,
      start: selection.start,
      end: selection.end,
    );
  }

  void _add(List<Attachment> files) {
    if (mounted) _logic.attach(files);
  }

  ComposerController get _controller => widget.config.controller;

  @override
  Future<void> edited(String text, int start, int end) async {
    int at(int offset) => offset.clamp(0, text.length);
    final value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: at(start), extentOffset: at(end)),
    );
    _reported = value;
    _outbox.rememberComposerValue(_valueOf(value));
    _controller.value = value;
    _reported = null;
  }

  @override
  void send() => _logic.submit();

  @override
  void queue() => _logic.submit(queue: true);

  @override
  void stop() => widget.config.onAbort();

  @override
  void voice() => widget.config.onVoice?.call();

  @override
  Future<void> attach(AttachKind kind) async => _add(
    await ref.read(attachmentPickerProvider).pick(switch (kind) {
      AttachKind.image => AttachmentKind.image,
      AttachKind.file => AttachmentKind.file,
    }),
  );

  @override
  Future<void> trigger(ComposerTrigger kind) async {
    _dismissed = null;
    openCompletion(_controller, completionOf(kind));
    if (mounted) setState(() {});
  }

  /// A row of the menu as last drawn.
  @override
  Future<void> pick(int index) async {
    final token = _token;
    if (token != null && index >= 0 && index < _matches.length) {
      acceptCompletion(_controller, token, _matches[index]);
    }
  }

  @override
  Future<void> dismiss() async {
    if (mounted) setState(() => _dismissed = _token);
  }

  @override
  void unattach(int index) => _logic.unattach(index);

  @override
  Future<void> unembed(int code) async {
    final embed = _controller.embedsByCode[code];
    if (embed != null) _controller.remove(embed);
  }

  /// Whether a paste took files from the clipboard.
  @override
  Future<bool> paste() async {
    final files = await ref.read(clipboardFilesProvider).read();
    _add(files);
    return files.isNotEmpty;
  }

  @override
  Future<void> copyCwd() async {
    final cwd = _cwd();
    if (cwd != null && mounted) {
      await copyToClipboard(context, cwd, said: "Copied working directory");
    }
  }

  /// Where a `!` command is about to run: the shell's own report where it has
  /// made one, else the workspace in the guest's own words. See
  /// `Composer._cwdBar`.
  String? _cwd() {
    final workspace = widget.config.workspace;
    if (workspace == null) return null;
    final live = ref
        .read(
          chatShellCwdProvider((
            workspace: workspace,
            workspaceHome: widget.config.workspaceHome,
          )),
        )
        ?.value;
    return live ??
        workingDirectoryFallback(
          workspace: workspace,
          guestRoot: ref.read(shellProvider).guestRoot,
          home: widget.config.workspaceHome,
        );
  }

  @override
  Widget build(BuildContext context) {
    final ProjectRef project = (
      device: widget.config.device,
      project: widget.config.project,
    );
    // Held while the composer is up, so a paired device's menu is there by
    // the time a `/` is typed.
    if (widget.config.device != null) ref.watch(promptLibraryOf(project));
    final cwd = widget.config.workspace == null
        ? null
        : ref.watch(
            chatShellCwdProvider((
              workspace: widget.config.workspace,
              workspaceHome: widget.config.workspaceHome,
            )),
          );
    final theme = Theme.of(context);
    // Both menus' entries, read here in the build rather than in the builder
    // below, which only knows which is open.
    final offered = {
      for (final kind in CompletionKind.values)
        kind: ref.watch(completionsProvider((project: project, kind: kind))),
    };
    // Every agent's face, drawn while the composer is up so the `@` menu has
    // them as it opens; a paired device's agents have none here.
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final outline = theme.colorScheme.outline.toARGB32();
    final faces = {
      if (widget.config.device == null)
        for (final agent in offered[CompletionKind.agent]!)
          agent.name: ref
              .watch(
                agentFacePngProvider((
                  project: widget.config.project,
                  name: agent.name,
                  size: _menuFace,
                  pixelRatio: pixelRatio,
                  outline: outline,
                )),
              )
              .value,
    };
    return ListenableBuilder(
      listenable: Listenable.merge([_shape, ?cwd]),
      builder: (context, _) {
        final controller = widget.config.controller;
        final token = activeCompletionToken(controller.value);
        if (token != _dismissed) _dismissed = null;
        final open = token != null && token != _dismissed;
        final options = open
            ? offered[token.kind]!
            : const <CompletionOption>[];
        _token = token;
        _matches = open ? matchingCompletions(options, token.query) : const [];
        final mode = _logic.mode;
        _outbox.composer(
          ComposerSnapshot(
            present: true,
            mode: switch (mode) {
              ComposerMode.message => InputMode.message,
              ComposerMode.shell => InputMode.shell,
              ComposerMode.callback => InputMode.callback,
            },
            hint: mode.hint ?? "Message",
            sendLabel: mode.sendLabel(queues: _logic.queues.value),
            canSend: _logic.canSend.value,
            queues: _logic.queues.value,
            speaking: widget.config.agentSpeaking,
            voice: widget.config.onVoice != null,
            maxLines: _logic.maxLines,
            attachments: [
              for (final a in _logic.attachments)
                ComposerAttachment(
                  name: a.filename,
                  image: a.mimeType.startsWith("image/"),
                ),
            ],
            menu: [
              for (final option in _matches)
                ComposerMenuItem(
                  label: "${token!.kind.trigger}${option.name}",
                  hint: option.argumentHint,
                  detail: option.description,
                  picture: token.kind == CompletionKind.agent
                      ? faces[option.name]
                      : null,
                ),
            ],
            cwd: mode == ComposerMode.shell ? _cwd() : null,
            cards: {
              for (final MapEntry(:key, :value)
                  in controller.embedsByCode.entries)
                key: ComposerCard(
                  title: value.card.title,
                  body: value.card.body,
                ),
            },
            accent: theme.colorScheme.primary.toARGB32(),
            dark: theme.brightness == Brightness.dark,
          ),
        );
        return const SizedBox.shrink();
      },
    );
  }
}

/// The window's title and toolbar for the page that builds this: the
/// chat's, or the new-chat screen's. A press on one of [items] runs its
/// entry in [actions].
class ShellChatBar extends ConsumerStatefulWidget {
  const ShellChatBar({
    super.key,
    required this.title,
    this.subtitle = "",
    this.expiresAt,
    this.items = const [],
    this.actions = const {},
  });

  final String title;
  final String subtitle;
  final DateTime? expiresAt;
  final List<TitleBarItem> items;
  final Map<String, VoidCallback> actions;

  @override
  ConsumerState<ShellChatBar> createState() => ShellChatBarState();
}

class ShellChatBarState extends ConsumerState<ShellChatBar>
    implements TitleBarIntents {
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  @override
  void dispose() {
    _slots.chatBar.leave(this);
    super.dispose();
  }

  /// The chat's bar has no way back: the conversation is the first page.
  @override
  Future<void> back() async {}

  /// A press on one of the items.
  @override
  void press(String id) => widget.actions[id]?.call();

  @override
  Widget build(BuildContext context) {
    // The last built is the one answering, as it is the one on screen.
    _slots.chatBar.claim(this);
    ref
        .read(shellOutboxProvider)
        .chatBar(
          TitleBarSnapshot(
            title: widget.title,
            subtitle: widget.subtitle,
            expiresAt: widget.expiresAt?.millisecondsSinceEpoch,
            items: widget.items,
          ),
        );
    return const SizedBox.shrink();
  }
}
