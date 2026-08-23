import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/shell.dart";
import "../../providers.dart";
import "text_input.dart";

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
/// offered here has to dispatch, so this matches `prompt_library.dart`'s
/// patterns — and, before them, that a `!` message goes to the shell, where
/// neither a command of Entoli's nor an agent means anything.
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
/// that is the only place `prompt_library.dart`'s `_command` reads one from, and a
/// mention's wherever the caret is.
int _triggerAt(TextEditingValue value, CompletionKind kind) => switch (kind) {
      CompletionKind.command => 0,
      CompletionKind.agent =>
        value.selection.isValid ? value.selection.baseOffset : value.text.length,
    };

/// Type a whole completion into [controller] — the trigger, the name, and the
/// trailing space that makes what follows arguments rather than more name.
///
/// Here rather than in the field's own state because the empty chat's starter
/// chips do the same thing from outside it, and the rule they have to agree on
/// is *where* it lands: appended wherever the caret was, a `/command` is text
/// the backend will never expand and the field's own menu will not recognise.
void insertCompletion(
  TextEditingController controller,
  CompletionKind kind,
  String name,
) {
  final value = controller.value;
  final at = _triggerAt(value, kind);
  final space = at > 0 && !_isSpace(value.text.codeUnitAt(at - 1)) ? " " : "";
  replaceIn(controller, at, at, "$space${kind.trigger}$name ");
}

/// The menu entries that open a completion menu by typing its trigger, for a
/// button that offers other things too — the composer's `+` also attaches
/// files. Each carries its action as its value, so it runs once the menu has
/// closed rather than under it.
List<PopupMenuItem<VoidCallback>> completionInsertItems(
  BuildContext context,
  GlobalKey<CompletionFieldState> field,
) {
  final theme = Theme.of(context);
  return [
    for (final kind in CompletionKind.values)
      PopupMenuItem(
        value: () => field.currentState?.openMenu(kind),
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
  ];
}

/// Where the menu goes relative to the field. The default stacks them, which is
/// the composer's arrangement of one field with a menu over it; a caller with a
/// row of buttons around the field passes its own.
typedef CompletionLayout = Widget Function(Widget menu, Widget field);

Widget _stacked(Widget menu, Widget field) =>
    Column(mainAxisSize: MainAxisSize.min, children: [menu, field]);

/// A text field that offers the app's `/commands` and `@agents` as they are
/// typed: a menu of what matches, arrows and tab and return to take one, and
/// escape to close it. Everywhere a prompt is written — the composer, and the
/// reminder editor — writes it into this, so the two cannot come to disagree
/// about what a trigger character does.
///
/// Nothing here asks for the field's focus unless [autofocus] is passed. On
/// Android that is the keyboard coming up, and beside a conversation it comes
/// up when the field is tapped and at no other time.
class CompletionField extends ConsumerStatefulWidget {
  const CompletionField({
    super.key,
    required this.controller,
    this.decoration,
    this.style,
    this.minLines,
    this.maxLines = 1,
    this.expands = false,
    this.autofocus = false,
    this.textAlignVertical,
    this.shortcuts = const <ShortcutActivator, Intent>{},
    this.actions = const <Type, Action<Intent>>{},
    this.layout = _stacked,
  });

  final TextEditingController controller;
  final InputDecoration? decoration;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final bool expands;
  final bool autofocus;
  final TextAlignVertical? textAlignVertical;

  /// The caller's own bindings, added to the menu's. The menu's win where both
  /// name a key, and it only binds any while it has something to pick.
  final Map<ShortcutActivator, Intent> shortcuts;
  final Map<Type, Action<Intent>> actions;

  final CompletionLayout layout;

  @override
  ConsumerState<CompletionField> createState() => CompletionFieldState();
}

class CompletionFieldState extends ConsumerState<CompletionField> {
  static const _rowHeight = 40.0;
  static const _visibleRows = 5;

  final ScrollController _scroll = ScrollController();
  CompletionToken? _token;
  int _highlighted = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncToken);
  }

  @override
  void didUpdateWidget(CompletionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncToken);
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

  /// Open [kind]'s menu by typing one — a command's trigger at the start of the
  /// message, the only place one is read from, and a mention's wherever the
  /// caret happens to be. The menu that opens is tapped rather than typed at,
  /// so the field is left unfocused.
  void openMenu(CompletionKind kind) {
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

  void _accept(CompletionOption option) {
    final token = _token;
    if (token == null) return;
    // The trailing space makes what follows arguments rather than more name.
    _replace(token.start, widget.controller.selection.baseOffset,
        "${token.kind.trigger}${option.name} ");
  }

  void _replace(int start, int end, String text) =>
      replaceIn(widget.controller, start, end, text);

  @override
  Widget build(BuildContext context) {
    final token = _token;
    final options = token == null
        ? const <CompletionOption>[]
        : ref.watch(completionsProvider(token.kind));
    final matches = _matching(options, token?.query ?? "");

    final field = Shortcuts(
      shortcuts: {
        ...widget.shortcuts,
        // Only while the menu has something to pick: otherwise these keys have
        // to keep doing what they do in a text box.
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
          ...widget.actions,
          _MoveIntent: CallbackAction<_MoveIntent>(
            onInvoke: (i) => _move(i.delta, matches.length),
          ),
          // `_highlighted` is read here rather than captured at build time: an
          // arrow and a return within one frame both have to land.
          _AcceptIntent: CallbackAction<_AcceptIntent>(
            onInvoke: (_) => _accept(matches[_highlighted % matches.length]),
          ),
          _DismissIntent: CallbackAction<_DismissIntent>(
            onInvoke: (_) => setState(() => _token = null),
          ),
        },
        child: TextField(
          controller: widget.controller,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          expands: widget.expands,
          autofocus: widget.autofocus,
          textAlignVertical: widget.textAlignVertical,
          style: widget.style,
          decoration: widget.decoration,
        ),
      ),
    );

    return widget.layout(
      token == null ? const SizedBox.shrink() : _menu(token.kind, matches),
      // Strictly outside the bindings above, so Tab reaches the indent only
      // when the menu had nothing to take it for. A one-line field is left
      // alone, since there Tab is how the caret leaves.
      widget.maxLines == 1
          ? field
          : TabIndents(controller: widget.controller, child: field),
    );
  }

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
