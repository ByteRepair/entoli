import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "../../../domain/shell.dart";
import "../../../providers.dart";
import "../../widgets/attachment_chip.dart";
import "code_block.dart";

class _SendIntent extends Intent {
  const _SendIntent();
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);
  final int delta;
}

class _AcceptIntent extends Intent {
  const _AcceptIntent();
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}

typedef CompletionToken = ({CompletionKind kind, int start, String query});

/// The word the caret sits in, when it is a trigger token. `/` only counts at
/// the very start of a message; `@` counts wherever a word begins. Anything
/// offered here has to dispatch, so this matches `BuiltinBackend`'s patterns —
/// the first of which is that a `!` message goes to the shell, where neither a
/// command of Entoli's nor an agent means anything.
CompletionToken? activeCompletionToken(TextEditingValue value) {
  if (shellBypassCommand(value.text) != null) return null;
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.baseOffset;
  if (caret > value.text.length) return null;

  var start = caret;
  while (start > 0 && !_isSpace(value.text.codeUnitAt(start - 1))) {
    start--;
  }
  if (start == caret) return null;

  final query = value.text.substring(start + 1, caret);
  return switch (value.text[start]) {
    "/" when start == 0 => (kind: CompletionKind.command, start: start, query: query),
    "@" => (kind: CompletionKind.agent, start: start, query: query),
    _ => null,
  };
}

/// Space, tab, newline — every break a typed message can hold.
bool _isSpace(int codeUnit) => codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A;

/// Where [kind]'s trigger goes: a command's at the start of the message, since
/// that is the only place `BuiltinBackend._command` reads one from, and a
/// mention's wherever the caret is.
int _triggerAt(TextEditingValue value, CompletionKind kind) => switch (kind) {
      CompletionKind.command => 0,
      CompletionKind.agent =>
        value.selection.isValid ? value.selection.baseOffset : value.text.length,
    };

void _replaceIn(TextEditingController controller, int start, int end, String text) {
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Type a whole completion into [controller] — the trigger, the name, and the
/// trailing space that makes what follows arguments rather than more name.
///
/// Here rather than in the composer's own state because the empty chat's
/// starter chips do the same thing from outside it, and the rule they have to
/// agree on is *where* it lands: appended wherever the caret was, a `/command`
/// is text the backend will never expand and the composer's own menu will not
/// recognise.
void insertCompletion(
  TextEditingController controller,
  CompletionKind kind,
  String name,
) {
  final value = controller.value;
  final at = _triggerAt(value, kind);
  final space = at > 0 && !_isSpace(value.text.codeUnitAt(at - 1)) ? " " : "";
  _replaceIn(controller, at, at, "$space${kind.trigger}$name ");
}

typedef SendCallback = void Function(String text, List<Attachment> attachments);

/// Message composer with send/abort toggle. Calls onSend with the typed text
/// and whatever is attached, then clears both; calls onAbort when a turn is
/// running. Typing `/` or `@` opens a menu of the app's commands or agents
/// above the field, and the `+` button also attaches files.
///
/// Nothing here asks for the field's focus. On Android that is the keyboard
/// coming up, and it comes up when the field is tapped and at no other time.
/// Dropping it again when the keyboard goes is `FocusFollowsKeyboard`'s, at the
/// root of the app.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.isRunning,
    required this.onSend,
    required this.onAbort,
    this.onVoice,
  });

  final TextEditingController controller;
  final bool isRunning;
  final SendCallback onSend;
  final VoidCallback onAbort;

  /// Opens voice mode. Null where the platform cannot listen at all, which is
  /// the web — the same rule that takes `bash` off the agent there.
  final VoidCallback? onVoice;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  static const _rowHeight = 40.0;
  static const _visibleRows = 5;

  final ScrollController _scroll = ScrollController();
  final List<Attachment> _attachments = [];
  CompletionToken? _token;

  /// This message is a command to run rather than something to say. Drawn
  /// rather than only obeyed: `!` sends the message somewhere else entirely,
  /// and nothing else in the composer would say so before Send is pressed.
  bool _shell = false;

  int _highlighted = 0;

  /// Whether Send would do anything. Kept here so only the button redraws when
  /// the answer flips, which is about twice a message.
  final ValueNotifier<bool> _canSend = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncToken);
  }

  @override
  void didUpdateWidget(Composer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_syncToken);
      widget.controller.addListener(_syncToken);
      _canSend.value = _worthSending;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncToken);
    _canSend.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncToken() {
    // Rides the listener the field already has. Its own notifier rather than a
    // `setState`, because the composer's build resolves the completion menu and
    // its matches, and that has no business re-running because Send went live.
    _canSend.value = _worthSending;
    final next = activeCompletionToken(widget.controller.value);
    final shell = shellBypassCommand(widget.controller.text) != null;
    if (next == _token && shell == _shell) return;
    setState(() {
      _token = next;
      _shell = shell;
      _highlighted = 0;
    });
  }

  void _move(int delta, int count) {
    setState(() => _highlighted = (_highlighted + delta) % count);
    _revealHighlighted();
  }

  void _revealHighlighted() {
    if (!_scroll.hasClients) return;
    final top = _highlighted * _rowHeight;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + viewport) {
      _scroll.jumpTo(top + _rowHeight - viewport);
    }
  }

  /// The `+` button opens the same menu the trigger characters do, by typing
  /// one — a command's at the start of the message, the only place one is read
  /// from, and a mention's wherever the caret happens to be. The menu that
  /// opens is tapped rather than typed at, so the field is left unfocused.
  void _openMenu(CompletionKind kind) {
    final value = widget.controller.value;
    if (kind == CompletionKind.command && value.text.startsWith(kind.trigger)) {
      widget.controller.selection = const TextSelection.collapsed(offset: 1);
    } else {
      final at = _triggerAt(value, kind);
      final space = at > 0 && !_isSpace(value.text.codeUnitAt(at - 1)) ? " " : "";
      _replace(at, at, "$space${kind.trigger}");
    }
    // A caret already in place notifies nothing, so a menu that was dismissed
    // has to be reopened by hand.
    _syncToken();
  }

  void _accept(CompletionOption option) {
    final token = _token;
    if (token == null) return;
    // The trailing space makes what follows arguments rather than more name.
    _replace(token.start, widget.controller.selection.baseOffset,
        "${token.kind.trigger}${option.name} ");
  }

  void _replace(int start, int end, String text) =>
      _replaceIn(widget.controller, start, end, text);

  Future<void> _attach(AttachmentKind kind) async {
    final picked = await ref.read(attachmentPickerProvider).pick(kind);
    if (picked.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(picked));
    _canSend.value = _worthSending;
  }

  /// A file on its own is worth sending, and whitespace on its own is not.
  bool get _worthSending =>
      widget.controller.text.trim().isNotEmpty || _attachments.isNotEmpty;

  void _submit() {
    // The button is dead when this is false, but Ctrl/Cmd+Enter reaches here
    // without passing it.
    if (!_worthSending) return;
    widget.onSend(widget.controller.text.trim(), List.of(_attachments));
    widget.controller.clear();
    setState(_attachments.clear);
    _canSend.value = _worthSending;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final token = _token;
    final options = token == null ? const <CompletionOption>[] : ref.watch(completionsProvider(token.kind));
    final matches = _matching(options, token?.query ?? "");

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (token != null) _menu(token.kind, matches),
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
                    for (final kind in CompletionKind.values)
                      PopupMenuItem(
                        value: () => _openMenu(kind),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(kind.label),
                            const SizedBox(width: 24),
                            Text(
                              kind.trigger,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                Expanded(
                  child: Shortcuts(
                    shortcuts: {
                      const SingleActivator(LogicalKeyboardKey.enter, control: true):
                          const _SendIntent(),
                      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                          const _SendIntent(),
                      // Only while the menu has something to pick: otherwise
                      // these keys have to keep doing what they do in a text box.
                      if (matches.isNotEmpty) ...{
                        const SingleActivator(LogicalKeyboardKey.arrowDown): const _MoveIntent(1),
                        const SingleActivator(LogicalKeyboardKey.arrowUp): const _MoveIntent(-1),
                        const SingleActivator(LogicalKeyboardKey.enter): const _AcceptIntent(),
                        const SingleActivator(LogicalKeyboardKey.tab): const _AcceptIntent(),
                        const SingleActivator(LogicalKeyboardKey.escape): const _DismissIntent(),
                      },
                    },
                    child: Actions(
                      actions: {
                        _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) => _submit()),
                        _MoveIntent: CallbackAction<_MoveIntent>(
                          onInvoke: (i) => _move(i.delta, matches.length),
                        ),
                        // `_highlighted` is read here rather than captured at
                        // build time: an arrow and a return within one frame both
                        // have to land.
                        _AcceptIntent: CallbackAction<_AcceptIntent>(
                          onInvoke: (_) => _accept(matches[_highlighted % matches.length]),
                        ),
                        _DismissIntent: CallbackAction<_DismissIntent>(
                          onInvoke: (_) => setState(() => _token = null),
                        ),
                      },
                      child: TextField(
                        controller: widget.controller,
                        minLines: 1,
                        maxLines: 6,
                        // The command in the face a command is read in, so what
                        // is about to run looks like what it is while it is
                        // still being typed.
                        style: _shell ? codeBlockStyle(theme) : null,
                        decoration: _shell ? _shellField(theme) : _messageField,
                      ),
                    ),
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
                    child: widget.onVoice == null || widget.isRunning || canSend
                        ? const SizedBox.shrink()
                        : child,
                  ),
                ),
                const SizedBox(width: 8),
                widget.isRunning
                    ? IconButton.filled(
                        onPressed: widget.onAbort,
                        icon: const Icon(Icons.stop),
                        tooltip: "Stop",
                      )
                    : ValueListenableBuilder<bool>(
                        valueListenable: _canSend,
                        builder: (context, canSend, _) => IconButton.filled(
                          onPressed: canSend ? _submit : null,
                          icon: Icon(_shell ? Icons.play_arrow : Icons.send),
                          tooltip: _shell ? "Run" : "Send",
                        ),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const _messageField = InputDecoration(
    hintText: "Message...",
    border: OutlineInputBorder(),
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

  PopupMenuItem<VoidCallback> _attachItem(IconData icon, String label, AttachmentKind kind) =>
      PopupMenuItem(
        value: () => _attach(kind),
        child: Row(
          children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
        ),
      );

  List<CompletionOption> _matching(List<CompletionOption> options, String query) {
    if (query.isEmpty) return options;
    final needle = query.toLowerCase();
    return options.where((o) => o.name.toLowerCase().contains(needle)).toList();
  }

  Widget _menu(CompletionKind kind, List<CompletionOption> matches) {
    if (matches.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: _rowHeight * _visibleRows),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: _list(kind, matches),
    );
  }

  Widget _list(CompletionKind kind, List<CompletionOption> matches) => ListView.builder(
    controller: _scroll,
    shrinkWrap: true,
    itemExtent: _rowHeight,
    itemCount: matches.length,
    itemBuilder: (context, i) {
      final theme = Theme.of(context);
      final option = matches[i];
      return InkWell(
        onTap: () => _accept(option),
        child: Container(
          color: i == _highlighted % matches.length
              ? theme.colorScheme.primaryContainer
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Text(
                "${kind.trigger}${option.name}",
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (option.description != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option.description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
