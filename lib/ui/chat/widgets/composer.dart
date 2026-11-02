import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../data/mime.dart" show pastedAttachment;
import "../../../domain/models.dart";
import "../../../domain/file_tools.dart" show guestWorkspacePath;
import "../../../providers.dart";
import "../../fonts.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/completion_field.dart";
import "../../widgets/dialogs.dart";
import "code_block.dart";
import "composer_controller.dart";
import "composer_embed.dart";
import "composer_logic.dart";

export "composer_logic.dart" show SendCallback;

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

  /// The main agent is speaking: Send becomes Stop and the voice button
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

class ComposerState extends ConsumerState<Composer> {
  final GlobalKey<CompletionFieldState> _field = GlobalKey();

  /// Held only so [embed] can put the caret in the field.
  final FocusNode _focus = FocusNode();

  /// The rules, which the native shell's composer shares. This build resolves
  /// the field's decoration and the buttons either side of it, so it follows
  /// the logic's shape and leaves Send's flips to the buttons' own builders.
  late final ComposerLogic _logic = ComposerLogic(widget.controller)
    ..addListener(_reshaped);
  late final Listenable _sendState = Listenable.merge([
    _logic.canSend,
    _logic.queues,
  ]);

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _logic.controller = widget.controller;
    _configure();
  }

  void _configure() => _logic.configure(
    agentSpeaking: widget.agentSpeaking,
    onSend: widget.onSend,
    onQueue: widget.onQueue,
    steers: widget.steers,
  );

  @override
  void dispose() {
    _logic.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reshaped() {
    if (mounted) setState(() {});
  }

  Future<void> _attach(AttachmentKind kind) async {
    _add(await ref.read(attachmentPickerProvider).pick(kind));
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
    if (mounted) _logic.attach(files);
  }

  /// Add [embed] to the message and put the caret on the line under it, so
  /// what is typed next answers it. Focused, unlike everything else here:
  /// choosing Reply is asking to write, and a caret left wherever the field
  /// last had one lands what is typed beside the card.
  void embed(ComposerEmbed embed) {
    widget.controller.append(embed);
    _focus.requestFocus();
  }

  /// Put back a message that was sent and taken back, ahead of whatever has
  /// been typed or attached since.
  void restore(Draft said) => _logic.restore(said);

  void _submit({bool queue = false}) => _logic.submit(queue: queue);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shell = _logic.mode == ComposerMode.shell;
    final wired = _logic.mode == ComposerMode.callback;
    final embeds = _logic.embeds;

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
          maxLines: 6 + 2 * embeds.clamp(0, 4),
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
              if (_logic.attachments.isNotEmpty)
                AttachmentStrip(
                  children: [
                    for (final (i, attachment) in _logic.attachments.indexed)
                      AttachmentChip.pending(
                        attachment,
                        onRemove: () => _logic.unattach(i),
                      ),
                  ],
                ),
              Row(
                children: [
                  // Each entry carries its action as its value, so it runs once
                  // the menu has closed rather than under it.
                  PopupMenuButton<VoidCallback>(
                    icon: const Icon(Icons.add),
                    tooltip: "Attach or insert",
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      _attachItem(
                        Icons.image_outlined,
                        "Image",
                        AttachmentKind.image,
                      ),
                      _attachItem(
                        Icons.attach_file,
                        "File",
                        AttachmentKind.file,
                      ),
                      const PopupMenuDivider(),
                      ...completionInsertItems(context, _field),
                    ],
                  ),
                  Expanded(child: field),
                  // The voice button and the field share the row, so the field
                  // gets the width back the moment there is a message in it:
                  // something typed is something to send rather than to say.
                  // `AnimatedSize` is the whole of the animation — the row is
                  // laid out again on every frame of it, and `Expanded` above
                  // takes whatever this gives up.
                  ValueListenableBuilder<bool>(
                    valueListenable: _logic.canSend,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: widget.onVoice,
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
                    valueListenable: _logic.queues,
                    builder: (context, queues, _) => AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      child: queues
                          ? Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: IconButton.outlined(
                                onPressed: () => _submit(queue: true),
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
                        widget.agentSpeaking && !_logic.canSend.value
                        ? IconButton.filled(
                            onPressed: widget.onAbort,
                            icon: const Icon(Icons.stop),
                            tooltip: "Stop",
                          )
                        : IconButton.filled(
                            onPressed: _logic.canSend.value ? _submit : null,
                            icon: Icon(
                              shell
                                  ? Icons.play_arrow
                                  : wired
                                  ? Icons.auto_awesome
                                  : Icons.send,
                            ),
                            tooltip: shell
                                ? "Run"
                                : wired
                                ? "Compact"
                                : _logic.queues.value
                                ? "Send now, read at its next step"
                                : "Send",
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
      hintText: "Shell command",
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
    hintText: "Compact the conversation",
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
    final fallback = () {
      final root = ref.watch(shellProvider).guestRoot;
      final home = widget.workspaceHome;
      return root != null && home != null
          ? guestWorkspacePath(root, home, workspace)
          : workspace;
    }();
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

  PopupMenuItem<VoidCallback> _attachItem(
    IconData icon,
    String label,
    AttachmentKind kind,
  ) => PopupMenuItem(
    value: () => _attach(kind),
    child: Row(
      children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
    ),
  );
}
