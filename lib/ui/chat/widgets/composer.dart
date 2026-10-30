import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "../../../domain/shell.dart";
import "../../../domain/file_tools.dart" show guestWorkspacePath;
import "../../../domain/wired_skill.dart";
import "../../../providers.dart";
import "../../fonts.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/completion_field.dart";
import "../../widgets/dialogs.dart";
import "code_block.dart";

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

typedef SendCallback = void Function(String text, List<Attachment> attachments);

/// Message composer with send/abort toggle. Calls onSend with the typed text
/// and whatever is attached, then clears both; calls onAbort when a turn is
/// running. While one runs, Send steers it and [onQueue] — the outlined
/// button beside Send, or Alt+Enter — holds the message for after it.
/// Typing `/` or `@` opens a menu of the app's commands or agents
/// above the field — that is [CompletionField]'s — and the `+` button also
/// attaches files.
///
/// Nothing here asks for the field's focus. On Android that is the keyboard
/// coming up, and it comes up when the field is tapped and at no other time.
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

  final TextEditingController controller;

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

  /// Opens voice mode. Null where the platform cannot listen at all, which is
  /// the web — the same rule that takes `bash` off the agent there.
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
  final List<Attachment> _attachments = [];

  /// This message is a command to run rather than something to say. Drawn
  /// rather than only obeyed: `!` sends the message somewhere else entirely,
  /// and nothing else in the composer would say so before Send is pressed.
  bool _shell = false;

  /// This message runs a callback rather than asking for anything said: a
  /// `/skill` flagged `invocation: callback` is one, and the composer says so
  /// the same way it says so for a command — from the keystroke that decides
  /// it, not from the turn that follows.
  bool _wired = false;

  /// Whether Send would do anything. Kept here so only the button redraws when
  /// the answer flips, which is about twice a message.
  final ValueNotifier<bool> _canSend = ValueNotifier(false);

  /// Whether what is typed would steer the running turn, so the queue button
  /// is on offer beside Send. A notifier for the reason [_canSend] is.
  final ValueNotifier<bool> _queues = ValueNotifier(false);
  late final Listenable _sendState = Listenable.merge([_canSend, _queues]);

  /// Whether the field has focus, so a browser's paste lands in the composer
  /// it was made in and not in every one listening.
  bool _focused = false;
  late final StreamSubscription<List<Attachment>> _pasted;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _pasted = ref.read(clipboardFilesProvider).pasted.listen((files) {
      if (_focused) _add(files);
    });
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _refresh();
    } else if (oldWidget.agentSpeaking != widget.agentSpeaking) {
      _refresh();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _pasted.cancel();
    _canSend.dispose();
    _queues.dispose();
    super.dispose();
  }

  void _sync() {
    // Its own notifier rather than a `setState`, because this build resolves
    // the field's decoration and the buttons either side of it, and that has no
    // business re-running because Send went live.
    _refresh();
    final shell = shellBypassCommand(widget.controller.text) != null;
    final wired = wiredSkillFromText(widget.controller.text) != null;
    if (shell == _shell && wired == _wired) return;
    setState(() {
      _shell = shell;
      _wired = wired;
    });
  }

  void _refresh() {
    final canSend = _worthSending;
    _canSend.value = canSend;
    // Only asked with something typed: the room composes a message to answer,
    // and a streaming reply rebuilds this page every frame.
    _queues.value = canSend &&
        widget.agentSpeaking &&
        widget.onQueue != null &&
        (widget.steers?.call(widget.controller.text) ?? false);
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
      Attachment(
          filename: name == null || name.isEmpty ? "pasted" : name,
          mimeType: content.mimeType,
          bytes: bytes),
    ]);
  }

  void _add(List<Attachment> files) {
    if (files.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(files));
    _refresh();
  }

  /// Put back a message that was sent and taken back, ahead of whatever has
  /// been typed or attached since.
  void restore(Draft said) {
    final (:text, :attachments) = said;
    final typed = widget.controller.text;
    widget.controller.text =
        typed.isEmpty || text.isEmpty ? "$text$typed" : "$text\n$typed";
    setState(() => _attachments.insertAll(0, attachments));
    _refresh();
  }

  /// A file on its own is worth sending, and whitespace on its own is not.
  bool get _worthSending =>
      widget.controller.text.trim().isNotEmpty || _attachments.isNotEmpty;

  void _submit({bool queue = false}) {
    // The button is dead when this is false, but Ctrl/Cmd+Enter reaches here
    // without passing it.
    if (!_worthSending) return;
    final send = queue && _queues.value ? widget.onQueue! : widget.onSend;
    send(widget.controller.text.trim(), List.of(_attachments));
    widget.controller.clear();
    setState(_attachments.clear);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(8),
        child: CompletionField(
          key: _field,
          controller: widget.controller,
          project: widget.project,
          device: widget.device,
          minLines: 1,
          maxLines: 6,
          // The command in the face a command is read in, so what is about to
          // run looks like what it is while it is still being typed.
          style: _shell ? codeBlockStyle(theme) : null,
          decoration: _shell
              ? _shellField(theme)
              : _wired
                  ? _wiredField(theme)
                  : _messageField,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter, control: true): _SendIntent(),
            SingleActivator(LogicalKeyboardKey.enter, meta: true): _SendIntent(),
            SingleActivator(LogicalKeyboardKey.enter, alt: true): _QueueIntent(),
          },
          actions: {
            PasteTextIntent: _PasteAction(_pasteFiles),
            _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) => _submit()),
            _QueueIntent: CallbackAction<_QueueIntent>(
                onInvoke: (_) => _submit(queue: true)),
          },
          contentInsertionConfiguration:
              ContentInsertionConfiguration(onContentInserted: _inserted),
          // The menu spans the composer rather than the field, so what it
          // offers is not squeezed by the buttons either side.
          layout: (menu, field) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              menu,
              if (_shell) _cwdBar(theme),
              if (_attachments.isNotEmpty)
                AttachmentStrip(
                  children: [
                    for (final (i, attachment) in _attachments.indexed)
                      AttachmentChip.pending(
                        attachment,
                        onRemove: () => setState(() => _attachments.removeAt(i)),
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
                      _attachItem(Icons.image_outlined, "Image", AttachmentKind.image),
                      _attachItem(Icons.attach_file, "File", AttachmentKind.file),
                      const PopupMenuDivider(),
                      ...completionInsertItems(context, _field),
                    ],
                  ),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) => _focused = focused,
                      child: field,
                    ),
                  ),
                  // The voice button and the field share the row, so the field
                  // gets the width back the moment there is a message in it:
                  // something typed is something to send rather than to say.
                  // `AnimatedSize` is the whole of the animation — the row is
                  // laid out again on every frame of it, and `Expanded` above
                  // takes whatever this gives up.
                  ValueListenableBuilder<bool>(
                    valueListenable: _canSend,
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
                      child: widget.onVoice == null || widget.agentSpeaking || canSend
                          ? const SizedBox.shrink()
                          : child,
                    ),
                  ),
                  // The quieter of the two ways to say something over a
                  // running turn, in the slot the voice button gives up:
                  // outlined beside the filled Send, which steers.
                  ValueListenableBuilder<bool>(
                    valueListenable: _queues,
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
                    builder: (context, _) => widget.agentSpeaking &&
                            !_canSend.value
                        ? IconButton.filled(
                            onPressed: widget.onAbort,
                            icon: const Icon(Icons.stop),
                            tooltip: "Stop",
                          )
                         : IconButton.filled(
                             onPressed: _canSend.value ? _submit : null,
                             icon: Icon(
                                 _shell
                                     ? Icons.play_arrow
                                     : _wired
                                         ? Icons.auto_awesome
                                         : Icons.send),
                             tooltip: _shell
                                 ? "Run"
                                 : _wired
                                     ? "Compact"
                                     : _queues.value
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
          borderSide:
              BorderSide(color: theme.colorScheme.tertiary, width: width),
        );
    return _messageField.copyWith(
      hintText: "Shell command",
      prefixIcon:
          Icon(Icons.terminal, size: 18, color: theme.colorScheme.tertiary),
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
        prefixIcon: Icon(Icons.auto_awesome,
            size: 18, color: theme.colorScheme.primary),
      );

  /// Where a `!` command is about to run: the shell's own directory, live,
  /// since a `cd` in an earlier one moved it. The completion menu's dressing,
  /// one row of it, and a tap copies the whole path out.
  Widget _cwdBar(ThemeData theme) {
    final workspace = widget.workspace;
    if (workspace == null) return const SizedBox.shrink();
    final notifier = ref.watch(chatShellCwdProvider(
        (workspace: workspace, workspaceHome: widget.workspaceHome)));
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
            onTap: () => copyToClipboard(context, live ?? fallback,
                said: "Copied working directory"),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.terminal,
                      size: 14, color: theme.colorScheme.onSurfaceVariant),
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

  PopupMenuItem<VoidCallback> _attachItem(IconData icon, String label, AttachmentKind kind) =>
      PopupMenuItem(
        value: () => _attach(kind),
        child: Row(
          children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
        ),
      );
}
