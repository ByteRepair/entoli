import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "../chat/widgets/composer.dart";
import "../chat/widgets/composer_embed.dart";
import "../chat/widgets/composer_logic.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "shell_outbox.dart";
import "shell_slots.dart";
import "snapshots.dart";

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
    implements ComposerHandle, ShellSurface {
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
    _slots.claim(ShellConcern.composer, this);
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
    if (_slots.leave(ShellConcern.composer, this)) {
      _outbox.post(ComposerSnapshot.absent);
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
    _outbox.say("composerFocus");
  }

  void _pushValue() {
    final value = widget.config.controller.value;
    if (value == _reported) return;
    _outbox.post(_valueOf(value));
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

  /// What the shell's composer sent. Answers what it waits on: whether a
  /// paste took files from the clipboard.
  @override
  Future<Object?> handle(String name, Map<String, Object?> args) async {
    final controller = widget.config.controller;
    switch (name) {
      case "edited":
        final text = args["text"]! as String;
        int at(String key) => (args[key]! as num).toInt().clamp(0, text.length);
        final value = TextEditingValue(
          text: text,
          selection: TextSelection(
            baseOffset: at("start"),
            extentOffset: at("end"),
          ),
        );
        _reported = value;
        _outbox.remember(_valueOf(value));
        controller.value = value;
        _reported = null;
      case "send":
        _logic.submit();
      case "queue":
        _logic.submit(queue: true);
      case "stop":
        widget.config.onAbort();
      case "voice":
        widget.config.onVoice?.call();
      case "attach":
        final kind = args["kind"] == "image"
            ? AttachmentKind.image
            : AttachmentKind.file;
        _add(await ref.read(attachmentPickerProvider).pick(kind));
      case "trigger":
        _dismissed = null;
        openCompletion(
          controller,
          args["kind"] == "@" ? CompletionKind.agent : CompletionKind.skill,
        );
        if (mounted) setState(() {});
      case "pick":
        final index = (args["index"]! as num).toInt();
        final token = _token;
        if (token != null && index >= 0 && index < _matches.length) {
          acceptCompletion(controller, token, _matches[index]);
        }
      case "dismiss":
        if (mounted) setState(() => _dismissed = _token);
      case "unattach":
        _logic.unattach((args["index"]! as num).toInt());
      case "unembed":
        final embed = controller.embedsByCode[(args["code"]! as num).toInt()];
        if (embed != null) controller.remove(embed);
      case "paste":
        final files = await ref.read(clipboardFilesProvider).read();
        _add(files);
        return files.isNotEmpty;
      case "copyCwd":
        final cwd = _cwd();
        if (cwd != null && mounted) {
          await copyToClipboard(context, cwd, said: "Copied working directory");
        }
    }
    return null;
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
        _outbox.post(
          ComposerSnapshot(
            present: true,
            mode: mode.name,
            hint: mode.hint ?? "Message",
            sendLabel: mode.sendLabel(queues: _logic.queues.value),
            canSend: _logic.canSend.value,
            queues: _logic.queues.value,
            speaking: widget.config.agentSpeaking,
            voice: widget.config.onVoice != null,
            maxLines: _logic.maxLines,
            attachments: [
              for (final a in _logic.attachments)
                (name: a.filename, image: a.mimeType.startsWith("image/")),
            ],
            menu: [
              for (final option in _matches)
                ComposerOptionSnapshot(
                  label: "${token!.kind.trigger}${option.name}",
                  hint: option.argumentHint,
                  description: option.description,
                ),
            ],
            cwd: mode == ComposerMode.shell ? _cwd() : null,
            cards: {
              for (final MapEntry(:key, :value)
                  in controller.embedsByCode.entries)
                key: value.card,
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
  final List<ToolbarItem> items;
  final Map<String, VoidCallback> actions;

  @override
  ConsumerState<ShellChatBar> createState() => ShellChatBarState();
}

class ShellChatBarState extends ConsumerState<ShellChatBar>
    implements ShellSurface {
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  @override
  void dispose() {
    _slots.leave(ShellConcern.toolbar, this);
    super.dispose();
  }

  /// A press on one of the items.
  @override
  Future<Object?> handle(String name, Map<String, Object?> args) async {
    widget.actions[args["id"]]?.call();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // The last built is the one answering, as it is the one on screen.
    _slots.claim(ShellConcern.toolbar, this);
    ref
        .read(shellOutboxProvider)
        .post(
          ChatBarSnapshot(
            title: widget.title,
            subtitle: widget.subtitle,
            expiresAt: widget.expiresAt?.millisecondsSinceEpoch,
            items: widget.items,
          ),
        );
    return const SizedBox.shrink();
  }
}
