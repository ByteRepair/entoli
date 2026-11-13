import "package:entoli_glass/entoli_glass.dart" hide ComposerAction;
import "package:entoli_glass/entoli_glass.dart" as shell show ComposerAction;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/composer.dart";
import "../../domain/goal.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show ProjectRef;
import "../../domain/wired_skill.dart";
import "../../app/settings/spec.dart" show SettingReader, WidgetReader;
import "../../providers.dart";
import "../chat/widgets/composer.dart";
import "../chat/widgets/composer_controller.dart";
import "../chat/widgets/composer_embed.dart";
import "faces.dart";
import "../widgets/completion_field.dart";
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

/// The composer as the shell draws it, apart from any widget: [model] over
/// [controller]'s text, bound to its turn by [binding], sent as a snapshot
/// and run from what the client says. The new-chat screen's widget and the
/// open chat's publisher (`ShellChat`) each hold one.
class ComposerSurface implements ComposerHandle, ComposerIntents {
  ComposerSurface({
    required this.outbox,
    required this.model,
    required this.controller,
    required this.clipboardFiles,
    this.focus,
  }) {
    focus?.addListener(_sendFocus);
    model.state.addListener(_follow);
    _follow();
  }

  final ShellOutbox outbox;
  final ComposerModel model;
  final ComposerController controller;

  /// What the clipboard holds as files, for a paste.
  final Future<List<Attachment>> Function() clipboardFiles;

  /// The native field's focus in Dart's focus tree, where there is one, so
  /// what takes focus away there takes the keyboard away from the field.
  final FocusNode? focus;

  ComposerBinding? _binding;

  /// The last revision of the model's state sent.
  int? _sentRevision;

  /// Whether the field has the keyboard, as it last said: a change of
  /// [focus] that agrees with it came from there and is not sent back.
  bool _fieldFocused = false;

  /// The menu as last drawn, which a `pick` names a row of.
  List<CompletionOption> _matches = const [];

  /// The model bound to [binding]'s turn, as it is now.
  void bind(ComposerBinding binding) {
    _binding = binding;
    model.bind(binding);
  }

  void dispose() {
    model.state.removeListener(_follow);
    focus?.removeListener(_sendFocus);
  }

  @override
  void restore(Draft said) => model.restore(said);

  /// Add [embed] and put the caret in the field, as [Composer.embed] does.
  @override
  void embed(ComposerEmbed embed) {
    controller.append(embed);
    final node = focus;
    node == null ? outbox.composerFocus(true) : node.requestFocus();
  }

  void _sendFocus() {
    final node = focus!;
    if (node.hasFocus != _fieldFocused) outbox.composerFocus(node.hasFocus);
  }

  @override
  void focused(bool focused) {
    _fieldFocused = focused;
    final node = focus;
    if (node == null) return;
    focused ? node.requestFocus() : node.unfocus();
  }

  /// What the core set goes to the shell's field, once per revision.
  void _follow() {
    final state = model.state.value;
    if (state.revision == _sentRevision) return;
    _sentRevision = state.revision;
    final (:text, :start, :end) = state.value;
    outbox.composerValue(
      ComposerValueSnapshot(
        text: text,
        start: start,
        end: end,
        revision: state.revision,
      ),
    );
  }

  @override
  Future<void> edited(String text, int start, int end) async =>
      model.edited((text: text, start: start, end: end));

  @override
  Future<void> run(shell.ComposerAction action) async {
    await model.run(composerActionOf(action));
  }

  /// A row of the menu as last drawn.
  @override
  Future<void> pick(int index) async {
    if (index >= 0 && index < _matches.length) {
      model.acceptCompletion(_matches[index].name);
    }
  }

  @override
  Future<void> dismiss() async => model.dismissCompletion();

  @override
  void unattach(int index) => model.unattach(index);

  @override
  Future<void> unembed(int code) async {
    final embed = controller.embedsByCode[code];
    if (embed != null) controller.remove(embed);
  }

  /// Whether a paste took files from the clipboard.
  @override
  Future<bool> paste() async {
    final files = await clipboardFiles();
    model.attach(files);
    return files.isNotEmpty;
  }

  /// The snapshot as things stand, what it reads watched through [reader]:
  /// the menus' entries, every agent's face for the `@` menu, where a `!`
  /// command would run. [pixelRatio] and [outline] are how a face is drawn.
  ComposerSnapshot snapshot(
    SettingReader reader, {
    required double pixelRatio,
    required Color outline,
  }) {
    final binding = _binding;
    if (binding == null) return ComposerSnapshot(present: false);
    final ProjectRef project = (
      device: binding.device,
      project: binding.project,
    );
    // Held while the composer is up, so a paired device's menu is there by
    // the time a `/` is typed.
    if (binding.device != null) reader.watch(promptLibraryOf(project));
    final offered = {
      for (final kind in CompletionKind.values)
        kind: reader.watch(completionsProvider((project: project, kind: kind))),
    };
    // Every agent's face, drawn while the composer is up so the `@` menu has
    // them as it opens; a paired device's agents have none here.
    final faces = {
      if (binding.device == null)
        for (final agent in offered[CompletionKind.agent]!)
          agent.name: reader
              .watch(
                agentFacePngProvider((
                  project: binding.project,
                  name: agent.name,
                  size: _menuFace,
                  pixelRatio: pixelRatio,
                  outline: outline,
                )),
              )
              .value,
    };
    final token = model.completion;
    _matches = token == null
        ? const []
        : matchingCompletions(offered[token.kind]!, token.query);
    final mode = model.mode;
    return ComposerSnapshot(
      present: true,
      mode: switch (mode) {
        ComposerMode.message => InputMode.message,
        ComposerMode.shell => InputMode.shell,
        ComposerMode.callback => InputMode.callback,
      },
      callback: switch (model.callback) {
        final wired? => callbackKindOf(wired),
        null => null,
      },
      canSend: model.canSend.value,
      queues: model.queues.value,
      speaking: model.speaking,
      voice: model.voice,
      attachments: [
        for (final a in model.attachments)
          ComposerAttachment(
            name: a.filename,
            image: a.mimeType.startsWith("image/"),
          ),
      ],
      menu: [
        for (final option in _matches)
          ComposerMenuItem(
            name: option.name,
            trigger: triggerOf(token!.kind),
            hint: option.argumentHint,
            detail: option.description,
            picture: token.kind == CompletionKind.agent
                ? faces[option.name]
                : null,
          ),
      ],
      cwd: mode == ComposerMode.shell ? _cwd(reader, binding) : null,
      cards: {
        for (final MapEntry(:key, :value) in controller.embedsByCode.entries)
          key: ComposerCard(title: value.card.title, body: value.card.body),
      },
    );
  }

  /// Where a `!` command is about to run: the shell's own report where it
  /// has made one, else the workspace in the guest's own words. See
  /// `Composer._cwdBar`.
  static String? _cwd(SettingReader reader, ComposerBinding binding) {
    final workspace = binding.workspace;
    if (workspace == null) return null;
    final live = reader
        .watch(
          chatShellCwdProvider((
            workspace: workspace,
            workspaceHome: binding.workspaceHome,
          )),
        )
        ?.value;
    return live ??
        workingDirectoryFallback(
          workspace: workspace,
          guestRoot: reader.read(shellProvider).guestRoot,
          home: binding.workspaceHome,
        );
  }

  /// What a snapshot is redrawn for besides what it watches: the model and
  /// the text.
  Listenable get shape =>
      Listenable.merge([model, model.canSend, model.queues, controller]);
}

/// The new-chat screen's composer, drawn by the native shell: a
/// [ComposerSurface] over the page's [model], bound by [binding].
class ShellComposer extends ConsumerStatefulWidget {
  const ShellComposer({
    super.key,
    required this.controller,
    required this.model,
    required this.binding,
  });

  final ComposerController controller;
  final ComposerModel model;
  final ComposerBinding binding;

  @override
  ConsumerState<ShellComposer> createState() => ShellComposerState();
}

class ShellComposerState extends ConsumerState<ShellComposer>
    implements ComposerHandle {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellAnswers _answers = ref.read(shellAnswersProvider);
  final FocusNode _focus = FocusNode(debugLabel: "ShellComposer");
  late ComposerSurface surface = _surface();

  ComposerSurface _surface() => ComposerSurface(
    outbox: _outbox,
    model: widget.model,
    controller: widget.controller,
    clipboardFiles: () => ref.read(clipboardFilesProvider).read(),
    focus: _focus,
  )..bind(widget.binding);

  @override
  void initState() {
    super.initState();
    _answers.composer.take(surface);
  }

  @override
  void didUpdateWidget(ShellComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      final owned = _answers.composer.release(surface);
      surface.dispose();
      surface = _surface();
      if (owned) _answers.composer.take(surface);
    }
    surface.bind(widget.binding);
  }

  @override
  void dispose() {
    surface.dispose();
    if (_answers.composer.release(surface)) {
      _outbox.composer(ComposerSnapshot(present: false));
    }
    _focus.dispose();
    super.dispose();
  }

  @override
  void restore(Draft said) => surface.restore(said);

  @override
  void embed(ComposerEmbed embed) => surface.embed(embed);

  @override
  Widget build(BuildContext context) {
    final binding = widget.binding;
    final cwd = binding.workspace == null
        ? null
        : ref.watch(
            chatShellCwdProvider((
              workspace: binding.workspace,
              workspaceHome: binding.workspaceHome,
            )),
          );
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final outline = Theme.of(context).colorScheme.outline;
    return Focus(
      focusNode: _focus,
      child: ListenableBuilder(
        listenable: Listenable.merge([surface.shape, ?cwd]),
        builder: (context, _) {
          _outbox.composer(
            surface.snapshot(
              WidgetReader(ref),
              pixelRatio: pixelRatio,
              outline: outline,
            ),
          );
          return const SizedBox.shrink();
        },
      ),
    );
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
