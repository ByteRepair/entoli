import "package:entoli_glass/entoli_glass.dart" hide ComposerAction;
import "package:entoli_glass/entoli_glass.dart" as shell show ComposerAction;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/composer.dart";
import "../../domain/goal.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../domain/wired_skill.dart";
import "../../providers.dart";
import "../chat/widgets/composer.dart";
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart";
import "../widgets/agent_picture.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart";
import "shell_outbox.dart";
import "shell_answers.dart";

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

/// The core's composer action for the contract's: the two are one list, and
/// a new one on either side does not compile until it is here.
ComposerAction composerActionOf(shell.ComposerAction action) =>
    switch (action) {
      shell.ComposerAction.send => ComposerAction.send,
      shell.ComposerAction.queue => ComposerAction.queue,
      shell.ComposerAction.stop => ComposerAction.stop,
      shell.ComposerAction.voice => ComposerAction.voice,
      shell.ComposerAction.attachImage => ComposerAction.attachImage,
      shell.ComposerAction.attachFile => ComposerAction.attachFile,
      shell.ComposerAction.insertSkill => ComposerAction.insertSkill,
      shell.ComposerAction.insertAgent => ComposerAction.insertAgent,
      shell.ComposerAction.newGoal => ComposerAction.newGoal,
    };

/// Which callback [wired] is, for the client to name.
CallbackKind callbackKindOf(WiredCall wired) => switch (wired.skill) {
  WiredSkill.compact => CallbackKind.compact,
  WiredSkill.goal => switch (goalCommandOf(wired.arguments)) {
    GoalSet() => CallbackKind.setGoal,
    GoalResume() => CallbackKind.resumeGoal,
    GoalPause() => CallbackKind.pauseGoal,
    GoalClear() => CallbackKind.clearGoal,
    GoalShow() => CallbackKind.showGoal,
  },
};

/// The composer, drawn by the native shell: configured by a [Composer] that
/// is never mounted, and run by the core's [ComposerModel], with no Flutter
/// of its own on screen. It sends the shell what to draw and runs what
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
  late final ShellAnswers _answers = ref.read(shellAnswersProvider);
  late final ComposerModel _model = ComposerModel(
    widget.config.controller,
    pick: (kind) => ref.read(attachmentPickerProvider).pick(kind),
  );
  late final Listenable _shape = Listenable.merge([
    _model,
    _model.canSend,
    _model.queues,
    widget.config.controller,
  ]);

  /// The last revision and focus request of the model's state acted on.
  int? _sentRevision;
  int? _seenFocus;

  /// The completion token a press of Escape closed the menu on; it stays
  /// closed until the caret is in another.
  CompletionToken? _dismissed;

  /// The native field's focus in Dart's focus tree, so what takes focus away
  /// here — a drag back through the conversation, a page pushed — takes the
  /// keyboard away there, as it would from a Flutter field.
  final FocusNode _focus = FocusNode(debugLabel: "ShellComposer");

  /// Whether the field has the keyboard, as it last said: a change of
  /// [_focus] that agrees with it came from there and is not sent back.
  bool _fieldFocused = false;

  /// The menu as last drawn, which a `pick` names a row of.
  List<CompletionOption> _matches = const [];
  CompletionToken? _token;

  @override
  void initState() {
    super.initState();
    _answers.composer.take(this);
    _focus.addListener(_sendFocus);
    _configure();
    _model.state.addListener(_follow);
    _seenFocus = _model.state.value.focusRequest;
    _follow();
  }

  @override
  void didUpdateWidget(ShellComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.controller != widget.config.controller) {
      _sentRevision = null;
      _model.field = widget.config.controller;
    }
    _configure();
  }

  @override
  void dispose() {
    _model.state.removeListener(_follow);
    if (_answers.composer.release(this)) {
      _outbox.composer(ComposerSnapshot(present: false));
    }
    _focus.dispose();
    _model.dispose();
    super.dispose();
  }

  void _configure() => _model.configure(
    agentSpeaking: widget.config.agentSpeaking,
    onSend: widget.config.onSend,
    onQueue: widget.config.onQueue,
    steers: widget.config.steers,
    onAbort: widget.config.onAbort,
    onVoice: widget.config.onVoice,
  );

  @override
  void restore(Draft said) => _model.restore(said);

  /// Add [embed] and put the caret in the field, as [Composer.embed] does.
  @override
  void embed(ComposerEmbed embed) {
    widget.config.controller.append(embed);
    _model.requestFocus();
  }

  void _sendFocus() {
    if (_focus.hasFocus != _fieldFocused) {
      _outbox.composerFocus(_focus.hasFocus);
    }
  }

  @override
  void focused(bool focused) {
    _fieldFocused = focused;
    focused ? _focus.requestFocus() : _focus.unfocus();
  }

  /// What the core set goes to the shell's field, once per revision, and a
  /// focus asked for takes the keyboard.
  void _follow() {
    final state = _model.state.value;
    if (state.revision != _sentRevision) {
      _sentRevision = state.revision;
      final (:text, :start, :end) = state.value;
      _outbox.composerValue(
        ComposerValueSnapshot(
          text: text,
          start: start,
          end: end,
          revision: state.revision,
        ),
      );
    }
    if (state.focusRequest != _seenFocus) {
      _seenFocus = state.focusRequest;
      _focus.requestFocus();
    }
  }

  void _add(List<Attachment> files) {
    if (mounted) _model.attach(files);
  }

  ComposerController get _controller => widget.config.controller;

  @override
  Future<void> edited(String text, int start, int end) async =>
      _model.edited((text: text, start: start, end: end));

  @override
  Future<void> run(shell.ComposerAction action) async {
    final run = composerActionOf(action);
    // A menu opened from the `+` is open again however it was dismissed.
    if (run == ComposerAction.insertSkill ||
        run == ComposerAction.insertAgent ||
        run == ComposerAction.newGoal) {
      _dismissed = null;
    }
    await _model.run(run);
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
  void unattach(int index) => _model.unattach(index);

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
    final outline = theme.colorScheme.outline;
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
    final composer = ListenableBuilder(
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
        final mode = _model.mode;
        _outbox.composer(
          ComposerSnapshot(
            present: true,
            mode: switch (mode) {
              ComposerMode.message => InputMode.message,
              ComposerMode.shell => InputMode.shell,
              ComposerMode.callback => InputMode.callback,
            },
            callback: switch (_model.callback) {
              final wired? => callbackKindOf(wired),
              null => null,
            },
            canSend: _model.canSend.value,
            queues: _model.queues.value,
            speaking: _model.speaking,
            voice: _model.voice,
            attachments: [
              for (final a in _model.attachments)
                ComposerAttachment(
                  name: a.filename,
                  image: a.mimeType.startsWith("image/"),
                ),
            ],
            menu: [
              for (final option in _matches)
                ComposerMenuItem(
                  label: "${token!.kind.trigger}${option.name}",
                  trigger: triggerOf(token.kind),
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
          ),
        );
        return const SizedBox.shrink();
      },
    );
    return Focus(focusNode: _focus, child: composer);
  }
}

/// The window's title and toolbar for the page that builds this: the
/// chat's, or the new-chat screen's, sent as the chat's state for the shell
/// to draw its own bar from. A press opens [onPlan] or [onSettings].
class ShellChatBar extends ConsumerStatefulWidget {
  const ShellChatBar({
    super.key,
    required this.bar,
    this.onPlan,
    this.onSettings,
  });

  final ChatBarSnapshot bar;
  final VoidCallback? onPlan;
  final VoidCallback? onSettings;

  @override
  ConsumerState<ShellChatBar> createState() => ShellChatBarState();
}

class ShellChatBarState extends ConsumerState<ShellChatBar>
    implements ChatBarIntents {
  late final ShellAnswers _answers = ref.read(shellAnswersProvider);

  @override
  void dispose() {
    _answers.chatBar.release(this);
    super.dispose();
  }

  @override
  void open(ChatBarDestination to) => switch (to) {
    ChatBarDestination.plan => widget.onPlan?.call(),
    ChatBarDestination.settings => widget.onSettings?.call(),
  };

  @override
  Widget build(BuildContext context) {
    // The last built is the one answering, as it is the one on screen.
    _answers.chatBar.take(this);
    ref.read(shellOutboxProvider).chatBar(widget.bar);
    return const SizedBox.shrink();
  }
}
