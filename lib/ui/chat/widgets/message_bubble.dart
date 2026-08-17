import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
// `SelectedContent`, which material does not re-export.
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../../domain/ask.dart";
import "../../../domain/models.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/dialogs.dart";
import "activity_label.dart";
import "code_block.dart";

/// Renders a single message. The bubble holds what the model said; thinking
/// and tool runs sit above it as labels, in the order they happened.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.chatId,
    required this.message,
    this.isWaiting = false,
    this.waitingNotice,
    this.threads,
    this.onThreadStep,
    this.onDelete,
    this.onEdit,
    this.onRegenerate,
    this.onTapLink,
  });

  /// Which chat's `resources/` the attachments are read back from.
  final String chatId;

  final Message message;

  /// This message is the one being generated right now.
  final bool isWaiting;

  /// Trouble reported while the turn is still running, e.g. a retry after a
  /// rate limit. Shown in red beside the spinner.
  final String? waitingNotice;

  /// The threads written where this message is, oldest first and including it.
  /// Null where nothing was branched here, which shows no counter and no
  /// arrows: one thread is nothing to say and nowhere to go. One value rather
  /// than a position and a count, which could disagree.
  final List<String>? threads;

  /// Read the thread this many along, -1 or 1.
  final ValueChanged<int>? onThreadStep;

  /// Delete this message and everything below it — the thread it heads.
  final VoidCallback? onDelete;

  /// Resend this message with different text. User messages only.
  final ValueChanged<String>? onEdit;

  /// Run the turn this message belongs to again, unchanged.
  final VoidCallback? onRegenerate;

  /// Open a link tapped in the rendered markdown. Receives the `href`.
  final ValueChanged<String>? onTapLink;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  /// Kept whether or not there is anything to show, so a message does not shift
  /// under the pointer the moment the actions appear.
  static const _actionsHeight = 28.0;

  bool _hovered = false;
  bool _tapped = false;
  Offset? _pressedAt;

  /// Uncovering the icons redraws the icons. A `setState` would rebuild the
  /// whole message — every label re-parsing its call's arguments — to change
  /// one opacity, and the pointer crosses a message twice on its way past.
  final ValueNotifier<bool> _shown = ValueNotifier(false);

  void _show({bool? hovered, bool? tapped}) {
    _hovered = hovered ?? _hovered;
    _tapped = tapped ?? _tapped;
    _shown.value = _hovered || _tapped;
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final edited = await promptForText(
      context,
      title: "Edit message",
      initial: widget.message.plainText,
      confirmLabel: "Send",
      maxLines: 8,
    );
    if (edited != null) widget.onEdit!(edited);
  }

  Future<void> _delete() async {
    final others = _threads - 1;
    final ok = await confirm(
      context,
      title: "Delete thread",
      // The last thread at a branch takes the rest of the conversation with it,
      // which is a different thing to be agreeing to.
      message: others > 0
          ? "This thread and everything below it will be removed. The other "
              "${others == 1 ? "one stays" : "$others stay"}."
          : "This message and everything below it will be removed.",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (ok) widget.onDelete!();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.message.plainText));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text("Message copied")));
  }

  bool get _hasError => widget.message.parts.whereType<ErrorPart>().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = widget.message.role == MessageRole.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // The reply has no tint behind it: it is the page rather than something
    // said to one side of it, which is what a null background draws.
    final (name, bg) = switch (widget.message.role) {
      MessageRole.user => ("You", theme.colorScheme.primaryContainer),
      MessageRole.assistant => ("Assistant", null),
      MessageRole.tool => ("Tool", theme.colorScheme.tertiaryContainer),
      MessageRole.system => ("System", theme.colorScheme.tertiaryContainer),
    };

    return MouseRegion(
      onEnter: (_) => _show(hovered: true),
      onExit: (_) => _show(hovered: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Listener(
              // A raw pointer listener sidesteps the gesture arena, which the
              // bubble's selection would otherwise win: a touch has to both
              // start a selection and show what can be done to the message.
              onPointerDown: (event) => _pressedAt = event.position,
              onPointerUp: (event) {
                final from = _pressedAt;
                _pressedAt = null;
                // A drag that began here was the list being scrolled, not this
                // message being touched.
                if (from == null || (event.position - from).distance > kTouchSlop) return;
                _show(tapped: !_tapped);
              },
              child: Column(
                crossAxisAlignment: align,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: Text(
                      name,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  // One region for the whole reply, so a drag runs from the
                  // first paragraph to the last rather than stopping at the
                  // bubble — or the tool label — it started in.
                  SelectionArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: align,
                      children: _rows(context, bg),
                    ),
                  ),
                ],
              ),
            ),
            _actions(theme),
          ],
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) => ValueListenableBuilder<bool>(
        valueListenable: _shown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_threads > 1) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  "${_thread + 1}/$_threads",
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              _step(theme, Icons.chevron_left, "Previous thread", -1),
              _step(theme, Icons.chevron_right, "Next thread", 1),
            ],
            if (widget.message.hasText)
              _action(theme, Icons.copy_outlined, "Copy message", _copy),
            if (widget.onDelete != null)
              _action(theme, Icons.delete_outline, "Delete thread", _delete),
            if (widget.onEdit != null) _action(theme, Icons.edit_outlined, "Edit", _edit),
            if (widget.onRegenerate != null)
              _action(theme, Icons.refresh, "Regenerate", widget.onRegenerate!),
          ],
        ),
        builder: (context, shown, child) => SizedBox(
          height: _actionsHeight,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: IgnorePointer(ignoring: !shown, child: child),
          ),
        ),
      );

  /// How many threads were written where this message is, and which of them it
  /// is. A message with none is a thread of one, and the only one.
  int get _threads => widget.threads?.length ?? 1;
  int get _thread => widget.threads?.indexOf(widget.message.id) ?? 0;

  /// An arrow to the thread [step] along, dead at either end of the list and
  /// while nothing is listening — the row is uncovered during a turn, when
  /// moving between threads is refused.
  Widget _step(ThemeData theme, IconData icon, String tooltip, int step) {
    final onStep = widget.onThreadStep;
    final to = _thread + step;
    return _action(theme, icon, tooltip,
        onStep == null || to < 0 || to >= _threads ? null : () => onStep(step));
  }

  Widget _action(ThemeData theme, IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        icon: Icon(icon, size: 16),
        tooltip: tooltip,
        onPressed: onPressed,
        color: theme.colorScheme.onSurfaceVariant,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 32, height: _actionsHeight),
      );

  /// The message split the way it reads: everything the model did on labels of
  /// its own, everything it said in a bubble, in the order it happened.
  List<Widget> _rows(BuildContext context, Color? bg) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    final spoken = <({String text, bool isError})>[];
    var files = widget.message.files.toList();

    final results = widget.message.toolResults;
    final calls = {
      for (final part in widget.message.parts.whereType<ToolCallPart>()) part.toolCall.id,
    };

    // Trailing state, not parts: they belong under the last thing said.
    final extras = <Widget>[
      if (widget.isWaiting && !widget.message.hasText)
        _Spinner(color: theme.colorScheme.onSurfaceVariant, notice: widget.waitingNotice),
      // A failed turn is a dead end without this; the same action is under the
      // message, but it should not have to be uncovered.
      if (_hasError && !widget.isWaiting && widget.onRegenerate != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onRegenerate,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text("Retry"),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
    ];

    void closeBubble({List<Widget> trailing = const []}) {
      if (spoken.isEmpty && trailing.isEmpty && files.isEmpty) return;
      rows.add(_bubble(context, bg, said: spoken.toList(), files: files, trailing: trailing));
      files = const [];
      spoken.clear();
    }

    for (var i = 0; i < widget.message.parts.length; i++) {
      final part = widget.message.parts[i];
      switch (part) {
        case ReasoningPart():
          closeBubble();
          rows.add(_label(ThinkingLabel(
            part: part,
            isLive:
                widget.isWaiting && part.durationMs == null && i == widget.message.parts.length - 1,
          )));
        case ToolCallPart(:final toolCall):
          closeBubble();
          rows.add(_label(switch (toolCall.name) {
            askToolName => AskLabel(call: toolCall, result: results[toolCall.id]),
            "task" => TaskLabel(call: toolCall, result: results[toolCall.id]),
            "websearch" => WebSearchLabel(call: toolCall, result: results[toolCall.id]),
            "webfetch" => WebFetchLabel(call: toolCall, result: results[toolCall.id]),
            _ => ToolLabel(call: toolCall, result: results[toolCall.id]),
          }));
        case ToolResultPart(:final result):
          // Already drawn by the call it answers, unless the call is gone.
          if (calls.contains(result.callId)) continue;
          closeBubble();
          rows.add(_label(ToolLabel(result: result)));
        case FilePart():
          continue;
        case TextPart(:final text):
          spoken.add((text: text, isError: false));
        case ErrorPart(:final message):
          spoken.add((text: "Error: $message", isError: true));
      }
    }
    closeBubble(trailing: extras);
    return rows;
  }

  /// A label sits inside the message's selection region but is not part of what
  /// the message says, so dragging past one must not put "Thought for 12
  /// seconds" on the clipboard. Its own drawer is a route and so is outside the
  /// region already.
  Widget _label(Widget child) => SelectionContainer.disabled(child: child);

  Widget _bubble(
    BuildContext context,
    Color? bg, {
    required List<({String text, bool isError})> said,
    required List<FilePart> files,
    required List<Widget> trailing,
  }) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (files.isNotEmpty)
          AttachmentStrip(
            children: [
              for (final f in files) AttachmentChip.sent(f, chatId: widget.chatId),
            ],
          ),
        for (final line in said)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _MessageText(
              text: line.text,
              isError: line.isError,
              isWaiting: widget.isWaiting,
              onTapLink: widget.onTapLink,
            ),
          ),
        ...trailing,
      ],
    );
    if (bg == null) return SizedBox(width: double.infinity, child: content);
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: content,
      ),
    );
  }
}

/// One line of a message bubble: raw text while the reply streams or when it is
/// an error, `MarkdownBody` once finished. Owns the markdown style sheet so the
/// parent's build does not rebuild it on every scroll frame.
class _MessageText extends StatefulWidget {
  const _MessageText({
    required this.text,
    required this.isError,
    required this.isWaiting,
    this.onTapLink,
  });

  final String text;
  final bool isError;
  final bool isWaiting;
  final ValueChanged<String>? onTapLink;

  @override
  State<_MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<_MessageText> {
  MarkdownStyleSheet? _styleSheet;

  /// Stateless and read only while the markdown is being parsed, so one is
  /// enough for every block this message holds.
  final _codeBlocks = CodeBlockBuilder();

  /// Built by the branch that has a source to hand back, and left null by the
  /// other — a reply streams for the whole of a turn and never renders while it
  /// does, so this is a delegate per finished text rather than per delta.
  _MarkdownSource? _selection;

  /// Raw while the reply streams or when it is an error: there is no markdown
  /// to render yet, and an error is not the model's prose.
  bool get _rendered => !widget.isWaiting && !widget.isError;

  @override
  void didUpdateWidget(_MessageText old) {
    super.didUpdateWidget(old);
    _selection?.source = widget.text;
  }

  @override
  void dispose() {
    _selection?.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _styleSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium,
      a: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: theme.colorScheme.primary,
      ),
      // `fromTheme` paints this in `cardColor`, which M3 defaults to
      // `colorScheme.surface` — the colour of the page the block is drawn on.
      codeblockDecoration: codeBlockDecoration(theme),
      // The block draws its own, around a bar the padding would push in with
      // the code.
      codeblockPadding: EdgeInsets.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_rendered) {
      return Text(
        widget.text,
        style: widget.isError
            ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)
            : theme.textTheme.bodyMedium,
      );
    }
    return SelectionContainer(
      delegate: _selection ??= _MarkdownSource(widget.text),
      // `selectable` builds a `SelectableText` per element, which is what made
      // a selection stop at the paragraph it started in. Plain `Text.rich`
      // joins the region above instead.
      child: MarkdownBody(
        data: widget.text,
        styleSheet: _styleSheet,
        builders: {"pre": _codeBlocks},
        onTapLink: (text, href, title) {
          if (href != null) widget.onTapLink?.call(href);
        },
      ),
    );
  }
}

/// What a selection of rendered markdown copies as. The renderer keeps no
/// source offsets, so there is nothing to map a partial selection back through
/// — anything selected inside a part copies the whole of that part's markdown,
/// which is what makes the clipboard hold `**bold**` rather than `bold`.
class _MarkdownSource extends StaticSelectionContainerDelegate {
  _MarkdownSource(this.source);

  String source;

  // `super` walks every selectable and concatenates what each holds, only for
  // the answer to be thrown away; the geometry already knows.
  @override
  SelectedContent? getSelectedContent() =>
      value.hasSelection ? SelectedContent(plainText: source) : null;
}

/// Stands in for the reply until the first text arrives.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.color, this.notice});
  final Color color;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          if (notice != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                notice!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Inline approval banner shown above the composer when a tool awaits approval.
class ApprovalBanner extends StatelessWidget {
  const ApprovalBanner({
    super.key,
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final ToolApproval approval;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.tertiary),
      ),
      child: Row(
        children: [
          Icon(Icons.shield, size: 18, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Approve ${approval.toolName}?",
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (approval.argumentsJson != null)
                  Text(
                    approval.argumentsJson!,
                    style: theme.textTheme.bodySmall?.copyWith(fontFamily: "monospace"),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onDeny, child: const Text("Deny")),
          FilledButton(onPressed: onAllow, child: const Text("Allow")),
        ],
      ),
    );
  }
}