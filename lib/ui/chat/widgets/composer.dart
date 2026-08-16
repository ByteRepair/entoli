import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/models.dart";
import "../../../providers.dart";
import "../../widgets/attachment_chip.dart";

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
/// offered here has to dispatch, so this matches `MinisweBackend`'s patterns.
CompletionToken? activeCompletionToken(TextEditingValue value) {
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

typedef SendCallback = void Function(String text, List<Attachment> attachments);

/// Message composer with send/abort toggle. Calls onSend with the typed text
/// and whatever is attached, then clears both; calls onAbort when a turn is
/// running. Typing `/` or `@` opens a menu of the app's commands or agents
/// above the field, and the `+` button also attaches files.
///
/// Nothing here asks for the field's focus. On Android that is the keyboard
/// coming up, and it comes up when the field is tapped and at no other time.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.isRunning,
    required this.onSend,
    required this.onAbort,
  });

  final TextEditingController controller;
  final bool isRunning;
  final SendCallback onSend;
  final VoidCallback onAbort;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  static const _rowHeight = 40.0;
  static const _visibleRows = 5;

  final ScrollController _scroll = ScrollController();
  final List<Attachment> _attachments = [];
  CompletionToken? _token;
  int _highlighted = 0;

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
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncToken);
    _scroll.dispose();
    super.dispose();
  }

  void _syncToken() {
    final next = activeCompletionToken(widget.controller.value);
    if (next == _token) return;
    setState(() {
      _token = next;
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
      final at = switch (kind) {
        CompletionKind.command => 0,
        CompletionKind.agent =>
          value.selection.isValid ? value.selection.baseOffset : value.text.length,
      };
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

  void _replace(int start, int end, String text) {
    widget.controller.value = TextEditingValue(
      text: widget.controller.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<void> _attach(AttachmentKind kind) async {
    final picked = await ref.read(attachmentPickerProvider).pick(kind);
    if (picked.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(picked));
  }

  void _submit() {
    final text = widget.controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    widget.onSend(text, List.of(_attachments));
    widget.controller.clear();
    setState(_attachments.clear);
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
                        decoration: const InputDecoration(
                          hintText: "Message...",
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                widget.isRunning
                    ? IconButton.filled(
                        onPressed: widget.onAbort,
                        icon: const Icon(Icons.stop),
                        tooltip: "Stop",
                      )
                    : IconButton.filled(
                        onPressed: _submit,
                        icon: const Icon(Icons.send),
                        tooltip: "Send",
                      ),
              ],
            ),
          ],
        ),
      ),
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
