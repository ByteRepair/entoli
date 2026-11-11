import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/mime.dart" show pastedAttachment;
import "../../../domain/models.dart";
import "../../../providers.dart";
import "../../fonts.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/completion_field.dart";
import "../../widgets/dialogs.dart";
import "../../../app/composer.dart";
import "code_block.dart";
import "composer_controller.dart";
import "composer_embed.dart";
import "composer_words.dart";

export "../../../app/composer.dart" show SendCallback;

/// What a page asks of whichever composer it has, the Flutter one or the
/// native shell's: a steer taken back put back, and a passage replied to.
abstract interface class ComposerHandle {
  void restore(Draft said);
  void embed(ComposerEmbed embed);
}

/// Where the Flutter composer puts a [ComposerAction]: a button of its own,
/// laid out by hand, or an entry of the `+` menu, divided by [_Plus.group].
sealed class _Place {
  const _Place();
}

class _Button extends _Place {
  const _Button();
}

class _Plus extends _Place {
  const _Plus(this.label, {this.icon, this.hint, required this.group});

  final String label;
  final IconData? icon;
  final String? hint;
  final int group;
}

/// Exhaustive, with no default: a new action does not compile until it has a
/// place here, or is left out on purpose.
_Place _place(ComposerAction action) => switch (action) {
  ComposerAction.send ||
  ComposerAction.queue ||
  ComposerAction.stop ||
  ComposerAction.voice => const _Button(),
  ComposerAction.attachImage => const _Plus(
    "Image",
    icon: Icons.image_outlined,
    group: 0,
  ),
  ComposerAction.attachFile => const _Plus(
    "File",
    icon: Icons.attach_file,
    group: 0,
  ),
  ComposerAction.insertSkill => _Plus(
    CompletionKind.skill.label,
    hint: CompletionKind.skill.trigger,
    group: 1,
  ),
  ComposerAction.insertAgent => _Plus(
    CompletionKind.agent.label,
    hint: CompletionKind.agent.trigger,
    group: 1,
  ),
  ComposerAction.newGoal => const _Plus(
    "New Goal",
    icon: Icons.track_changes,
    group: 2,
  ),
};

class _SendIntent extends Intent {
  const _SendIntent();
}

class _QueueIntent extends Intent {
  const _QueueIntent();
}

/// Ctrl/Cmd+V over the field's own paste: files on the clipboard are
/// attached, and anything else goes to the field. The field's action is
/// captured before the await, since it is only set for the call.
class _PasteAction extends Action<PasteTextIntent> {
  _PasteAction(this.attach);

  final Future<bool> Function() attach;

  @override
  Future<void> invoke(PasteTextIntent intent) async {
    final paste = callingAction;
    if (!await attach()) paste?.invoke(intent);
  }
}

/// Message composer with send/abort toggle. Calls onSend with the typed text
/// and whatever is attached, then clears both; calls onAbort when a turn is
/// running. While one runs, Send steers it and [onQueue] — the outlined
/// button beside Send, or Alt+Enter — holds the message for after it.
/// Typing `/` or `@` opens a menu of the app's commands or agents
/// above the field — that is [CompletionField]'s — and the `+` button also
/// attaches files.
///
/// Nothing here asks for the field's focus but [ComposerState.embed]. On
/// Android that is the keyboard coming up, and it comes up when the field is
/// tapped, or when the user chose Reply on a passage — which is asking to
/// write — and at no other time.
/// Dropping it again when the keyboard goes is `FocusFollowsKeyboard`'s, at the
/// root of the app.
class Composer extends ConsumerStatefulWidget {
  const Composer({
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

  /// The field, and the quotes and other embeds in it. What is sent is its
  /// `message`, never its `text`.
  final ComposerController controller;

  /// A participant is speaking: Send becomes Stop and the voice button
  /// stands down.
  final bool agentSpeaking;
  final SendCallback onSend;
  final VoidCallback onAbort;

  /// Send for after the running turn rather than into it. Null where the
  /// composer has no turn to wait on.
  final SendCallback? onQueue;

  /// Whether what is typed would steer the running turn: the room's rule,
  /// asked rather than copied, since only it knows who is speaking. Given
  /// with [onQueue]; without it the queue button never shows.
  final bool Function(String text)? steers;

  /// The project the composer is in, so the `/` and `@` menus offer what it
  /// offers. Null is the default, the way it is everywhere a project is named.
  final String? project;

  /// The paired device [project] is on, null for this one.
  final String? device;

  /// Opens voice mode. Null draws no voice button.
  final VoidCallback? onVoice;

  /// Where this chat's shell starts: its own workspace. Null where the chat
  /// does not exist yet, which draws no bar at all. Drawn in shell mode, live
  /// as a `cd` moves it, and copied whole on a tap.
  final String? workspace;

  /// The project workspace the shell's turns call home — what words the bar's
  /// fallback in the guest's vocabulary where this shell has one. Null beside
  /// a null [workspace] only: they travel together from the page.
  final String? workspaceHome;

  @override
  ConsumerState<Composer> createState() => ComposerState();
}

class ComposerState extends ConsumerState<Composer> implements ComposerHandle {
  final GlobalKey<CompletionFieldState> _field = GlobalKey();

  /// Held only so [embed] can put the caret in the field.
  final FocusNode _focus = FocusNode();

  /// The core's model, which the native shell's composer runs on too. This
  /// build resolves the field's decoration and the buttons either side of
  /// it, so it follows the model's shape and leaves Send's flips to the
  /// buttons' own builders.
  late final ComposerModel _model = ComposerModel(
    widget.controller,
    pick: (kind) => ref.read(attachmentPickerProvider).pick(kind),
  )..addListener(_reshaped);
  late final Listenable _sendState = Listenable.merge([
    _model.canSend,
    _model.queues,
  ]);

  @override
  void initState() {
    super.initState();
    _configure();
    _model.state.addListener(_followFocus);
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _model.field = widget.controller;
    _configure();
  }

  void _configure() => _model.configure(
    agentSpeaking: widget.agentSpeaking,
    onSend: widget.onSend,
    onQueue: widget.onQueue,
    steers: widget.steers,
    onAbort: widget.onAbort,
    onVoice: widget.onVoice,
  );

  @override
  void dispose() {
    _model.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reshaped() {
    if (mounted) setState(() {});
  }

  /// Attach what the clipboard holds other than text. False where it held
  /// none, and the paste is the field's.
  Future<bool> _pasteFiles() async {
    final files = await ref.read(clipboardFilesProvider).read();
    _add(files);
    return files.isNotEmpty;
  }

  /// A keyboard's image, which Android's keyboards hand over as content
  /// rather than through the clipboard.
  void _inserted(KeyboardInsertedContent content) {
    final bytes = content.data;
    if (bytes == null) return;
    final name = Uri.tryParse(content.uri)?.pathSegments.lastOrNull;
    _add([
      pastedAttachment(
        bytes,
        name: name == null || name.isEmpty ? null : name,
        declared: content.mimeType,
      ),
    ]);
  }

  void _add(List<Attachment> files) {
    if (mounted) _model.attach(files);
  }

  /// Add [embed] to the message and put the caret on the line under it, so
  /// what is typed next answers it. Focused, unlike everything else here:
  /// choosing Reply is asking to write, and a caret left wherever the field
  /// last had one lands what is typed beside the card.
  @override
  void embed(ComposerEmbed embed) {
    widget.controller.append(embed);
    _model.requestFocus();
  }

  late int _seenFocus = _model.state.value.focusRequest;

  void _followFocus() {
    final asked = _model.state.value.focusRequest;
    if (asked == _seenFocus) return;
    _seenFocus = asked;
    _focus.requestFocus();
  }

  /// Put back a message that was sent and taken back, ahead of whatever has
  /// been typed or attached since.
  @override
  void restore(Draft said) => _model.restore(said);

  void _submit({bool queue = false}) => _model.submit(queue: queue);

  /// How many lines the field grows to before it scrolls: two more per embed,
  /// each taller than a line, up to four of them.
  int get _maxLines => 6 + 2 * _model.embeds.clamp(0, 4);

  Future<void> _run(ComposerAction action) async {
    await _model.run(action);
    if (action == ComposerAction.insertSkill ||
        action == ComposerAction.insertAgent) {
      _field.currentState?.reopen();
    }
  }

  List<PopupMenuEntry<ComposerAction>> _plusMenu(BuildContext context) {
    final theme = Theme.of(context);
    final entries = <PopupMenuEntry<ComposerAction>>[];
    int? group;
    for (final action in ComposerAction.values) {
      if (_place(action) case final _Plus entry) {
        if (group != null && entry.group != group) {
          entries.add(const PopupMenuDivider());
        }
        group = entry.group;
        entries.add(_plusItem(theme, action, entry));
      }
    }
    return entries;
  }

  PopupMenuItem<ComposerAction> _plusItem(
    ThemeData theme,
    ComposerAction action,
    _Plus entry,
  ) => PopupMenuItem(
    value: action,
    child: Row(
      mainAxisAlignment: entry.hint == null
          ? MainAxisAlignment.start
          : MainAxisAlignment.spaceBetween,
      children: [
        if (entry.icon case final icon?) ...[
          Icon(icon, size: 18),
          const SizedBox(width: 12),
        ],
        Text(entry.label),
        if (entry.hint case final hint?) ...[
          const SizedBox(width: 24),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shell = _model.mode == ComposerMode.shell;
    final wired = _model.mode == ComposerMode.callback;
    final embeds = _model.embeds;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(8),
        child: CompletionField(
          key: _field,
          focusNode: _focus,
          controller: widget.controller,
          project: widget.project,
          device: widget.device,
          minLines: 1,
          maxLines: _maxLines,
          // The command in the face a command is read in, so what is about to
          // run looks like what it is while it is still being typed.
          style: shell ? codeBlockStyle(theme) : null,
          // A field's lines are held to the text's height unless told
          // otherwise, which would lay a card over the lines either side of
          // it; the strut is then a floor rather than the height.
          strutStyle: embeds > 0
              ? const StrutStyle(forceStrutHeight: false)
              : null,
          decoration: shell
              ? _shellField(theme)
              : wired
              ? _wiredField(theme)
              : _messageField,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter, control: true):
                _SendIntent(),
            SingleActivator(LogicalKeyboardKey.enter, meta: true):
                _SendIntent(),
            SingleActivator(LogicalKeyboardKey.enter, alt: true):
                _QueueIntent(),
          },
          actions: {
            PasteTextIntent: _PasteAction(_pasteFiles),
            _SendIntent: CallbackAction<_SendIntent>(
              onInvoke: (_) => _submit(),
            ),
            _QueueIntent: CallbackAction<_QueueIntent>(
              onInvoke: (_) => _submit(queue: true),
            ),
          },
          contentInsertionConfiguration: ContentInsertionConfiguration(
            onContentInserted: _inserted,
          ),
          // The menu spans the composer rather than the field, so what it
          // offers is not squeezed by the buttons either side.
          layout: (menu, field) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              menu,
              if (shell) _cwdBar(theme),
              if (_model.attachments.isNotEmpty)
                AttachmentStrip(
                  children: [
                    for (final (i, attachment) in _model.attachments.indexed)
                      AttachmentChip.pending(
                        attachment,
                        onRemove: () => _model.unattach(i),
                      ),
                  ],
                ),
              Row(
                children: [
                  // Each entry carries its action as its value, so it runs once
                  // the menu has closed rather than under it.
                  PopupMenuButton<ComposerAction>(
                    icon: const Icon(Icons.add),
                    tooltip: "Attach or insert",
                    onSelected: _run,
                    itemBuilder: _plusMenu,
                  ),
                  Expanded(child: field),
                  // The voice button and the field share the row, so the field
                  // gets the width back the moment there is a message in it:
                  // something typed is something to send rather than to say.
                  // `AnimatedSize` is the whole of the animation — the row is
                  // laid out again on every frame of it, and `Expanded` above
                  // takes whatever this gives up.
                  ValueListenableBuilder<bool>(
                    valueListenable: _model.canSend,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: () => _run(ComposerAction.voice),
                          icon: const Icon(Icons.circle_outlined),
                          tooltip: "Voice mode",
                        ),
                      ],
                    ),
                    builder: (context, canSend, child) => AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child:
                          widget.onVoice == null ||
                              widget.agentSpeaking ||
                              canSend
                          ? const SizedBox.shrink()
                          : child,
                    ),
                  ),
                  // The quieter of the two ways to say something over a
                  // running turn, in the slot the voice button gives up:
                  // outlined beside the filled Send, which steers.
                  ValueListenableBuilder<bool>(
                    valueListenable: _model.queues,
                    builder: (context, queues, _) => AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: queues
                          ? Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: IconButton.outlined(
                                onPressed: () => _run(ComposerAction.queue),
                                icon: const Icon(Icons.schedule_send),
                                tooltip: "Send after this turn (Alt+Enter)",
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Empty field while the agent speaks is Stop; anything
                  // typed is Send, which the turn reads at its next step —
                  // the room's rule is the controller's, and the button
                  // only names which of the two is on offer.
                  ListenableBuilder(
                    listenable: _sendState,
                    builder: (context, _) =>
                        widget.agentSpeaking && !_model.canSend.value
                        ? IconButton.filled(
                            onPressed: () => _run(ComposerAction.stop),
                            icon: const Icon(Icons.stop),
                            tooltip: "Stop",
                          )
                        : IconButton.filled(
                            onPressed: _model.canSend.value
                                ? () => _run(ComposerAction.send)
                                : null,
                            icon: Icon(
                              shell
                                  ? Icons.play_arrow
                                  : wired
                                  ? Icons.auto_awesome
                                  : Icons.send,
                            ),
                            tooltip: _model.mode.sendLabel(
                              queues: _model.queues.value,
                              callback: _model.callback,
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _messageField = InputDecoration(
    hintText: "Message...",
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );

  /// The same field, dressed as what it is about to do. Both borders are
  /// given, or it goes back to the ordinary outline the moment it takes focus —
  /// which is exactly while a command is being typed.
  InputDecoration _shellField(ThemeData theme) {
    OutlineInputBorder outline(double width) => OutlineInputBorder(
      borderSide: BorderSide(color: theme.colorScheme.tertiary, width: width),
    );
    return _messageField.copyWith(
      hintText: ComposerMode.shell.hint,
      prefixIcon: Icon(
        Icons.terminal,
        size: 18,
        color: theme.colorScheme.tertiary,
      ),
      filled: true,
      fillColor: theme.colorScheme.surfaceContainerHighest,
      enabledBorder: outline(1),
      focusedBorder: outline(2),
    );
  }

  /// The field dressed for a callback: a hint and an icon, nothing more. A
  /// callback is not sent to a model and runs nothing on the machine — the
  /// command's dressing would say more than is true.
  InputDecoration _wiredField(ThemeData theme) => _messageField.copyWith(
    hintText: ComposerMode.callback.hint,
    prefixIcon: Icon(
      Icons.auto_awesome,
      size: 18,
      color: theme.colorScheme.primary,
    ),
  );

  /// Where a `!` command is about to run: the shell's own directory, live,
  /// since a `cd` in an earlier one moved it. The completion menu's dressing,
  /// one row of it, and a tap copies the whole path out.
  Widget _cwdBar(ThemeData theme) {
    final workspace = widget.workspace;
    if (workspace == null) return const SizedBox.shrink();
    final notifier = ref.watch(
      chatShellCwdProvider((
        workspace: workspace,
        workspaceHome: widget.workspaceHome,
      )),
    );
    // What stands in for the shell having said nothing yet, in the row's own
    // words: the guest's vocabulary where this shell has one, so a chat
    // reopened before its next command says where the command will run and
    // not the host path it is keyed by.
    final fallback = workingDirectoryFallback(
      workspace: workspace,
      guestRoot: ref.watch(shellProvider).guestRoot,
      home: widget.workspaceHome,
    );
    Widget row(String? live) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(minHeight: 32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => copyToClipboard(
          context,
          live ?? fallback,
          said: "Copied working directory",
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                Icons.terminal,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  live ?? fallback,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: monoFamily,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (notifier == null) return row(null);
    return ValueListenableBuilder<String?>(
      valueListenable: notifier,
      builder: (context, value, _) => row(value),
    );
  }
}
