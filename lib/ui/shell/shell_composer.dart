import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/file_tools.dart" show guestWorkspacePath;
import "../../domain/models.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../providers.dart";
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart";
import "../chat/widgets/composer_logic.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "shell_outbox.dart";
import "snapshots.dart";

/// Where the shell's composer and chat bar intents go: the ones on screen.
/// A page sets itself here when it is built and clears itself when it goes,
/// so the last one built is the one answering.
class ShellSlots {
  ShellComposerState? composer;
  ShellChatBarState? bar;
}

final shellSlotsProvider = Provider<ShellSlots>((ref) => ShellSlots());

/// The composer, drawn by the native shell: [Composer]'s arguments, and its
/// rules through the same [ComposerLogic], with no Flutter of its own on
/// screen. It sends the shell what to draw and runs what the user did there;
/// the text is Dart's, in [controller], as it is for [Composer].
class ShellComposer extends ConsumerStatefulWidget {
  const ShellComposer({
    super.key,
    required this.controller,
    required this.agentSpeaking,
    required this.onSend,
    required this.onAbort,
    this.onQueue,
    this.steers,
    this.project,
    this.device,
    this.onVoice,
    this.workspace,
    this.workspaceHome,
  });

  final ComposerController controller;
  final bool agentSpeaking;
  final SendCallback onSend;
  final VoidCallback onAbort;
  final SendCallback? onQueue;
  final bool Function(String text)? steers;
  final String? project;
  final String? device;
  final VoidCallback? onVoice;
  final String? workspace;
  final String? workspaceHome;

  @override
  ConsumerState<ShellComposer> createState() => ShellComposerState();
}

class ShellComposerState extends ConsumerState<ShellComposer>
    implements ComposerHandle {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);
  late final ComposerLogic _logic = ComposerLogic(widget.controller);
  late final Listenable _shape = Listenable.merge([
    _logic,
    _logic.canSend,
    _logic.queues,
    widget.controller,
  ]);

  /// The value the shell last reported, so a change it made is not sent back
  /// to it — which mid-composition would undo the input method's marked text.
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
    _slots.composer = this;
    _configure();
    widget.controller.addListener(_pushValue);
    _pushValue();
  }

  @override
  void didUpdateWidget(ShellComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_pushValue);
      widget.controller.addListener(_pushValue);
      _logic.controller = widget.controller;
      _pushValue();
    }
    _configure();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pushValue);
    if (_slots.composer == this) {
      _slots.composer = null;
      _outbox.post(ComposerSnapshot.absent);
    }
    _logic.dispose();
    super.dispose();
  }

  void _configure() => _logic.configure(
    agentSpeaking: widget.agentSpeaking,
    onSend: widget.onSend,
    onQueue: widget.onQueue,
    steers: widget.steers,
  );

  @override
  void restore(Draft said) => _logic.restore(said);

  /// Add [embed] and put the caret in the field, as [Composer.embed] does.
  @override
  void embed(ComposerEmbed embed) {
    widget.controller.append(embed);
    _outbox.say("composerFocus");
  }

  void _pushValue() {
    final value = widget.controller.value;
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
  Future<Object?> handle(String name, Map<String, Object?> args) async {
    final controller = widget.controller;
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
      case "send":
        _logic.submit();
      case "queue":
        _logic.submit(queue: true);
      case "stop":
        widget.onAbort();
      case "voice":
        widget.onVoice?.call();
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
    final workspace = widget.workspace;
    if (workspace == null) return null;
    final live = ref
        .read(
          chatShellCwdProvider((
            workspace: workspace,
            workspaceHome: widget.workspaceHome,
          )),
        )
        ?.value;
    if (live != null) return live;
    final root = ref.read(shellProvider).guestRoot;
    final home = widget.workspaceHome;
    return root != null && home != null
        ? guestWorkspacePath(root, home, workspace)
        : workspace;
  }

  @override
  Widget build(BuildContext context) {
    final ProjectRef project = (device: widget.device, project: widget.project);
    // Held while the composer is up, so a paired device's menu is there by
    // the time a `/` is typed.
    if (widget.device != null) ref.watch(promptLibraryOf(project));
    final cwd = widget.workspace == null
        ? null
        : ref.watch(
            chatShellCwdProvider((
              workspace: widget.workspace,
              workspaceHome: widget.workspaceHome,
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
        final controller = widget.controller;
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
            hint: switch (mode) {
              ComposerMode.shell => "Shell command",
              ComposerMode.callback => "Compact the conversation",
              ComposerMode.message => "Message",
            },
            sendLabel: switch (mode) {
              ComposerMode.shell => "Run",
              ComposerMode.callback => "Compact",
              ComposerMode.message =>
                _logic.queues.value
                    ? "Send now, read at its next step"
                    : "Send",
            },
            canSend: _logic.canSend.value,
            queues: _logic.queues.value,
            speaking: widget.agentSpeaking,
            voice: widget.onVoice != null,
            maxLines: 6 + 2 * _logic.embeds.clamp(0, 4),
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

class ShellChatBarState extends ConsumerState<ShellChatBar> {
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  @override
  void initState() {
    super.initState();
    _slots.bar = this;
  }

  @override
  void dispose() {
    if (_slots.bar == this) _slots.bar = null;
    super.dispose();
  }

  void press(String id) => widget.actions[id]?.call();

  @override
  Widget build(BuildContext context) {
    // The last built is the one answering, as it is the one on screen.
    _slots.bar = this;
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
