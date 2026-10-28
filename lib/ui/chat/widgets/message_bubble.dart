import "dart:async";
import "dart:math" as math;
import "dart:typed_data";

import "package:flutter/foundation.dart" show defaultTargetPlatform;
import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
// `SelectedContent`, which material does not re-export.
import "package:flutter/rendering.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../../core/platform/rich_clipboard.dart";
import "../../../domain/formatted_text.dart";
import "../../../domain/models.dart";
import "../../../domain/shell.dart";
import "../../../domain/wired_skill.dart";
import "../../widgets/action_icon.dart";
import "../../widgets/agent_picture.dart" show AgentPictureImage;
import "../../widgets/attachment_chip.dart";
import "../../theme.dart" show onFillTheme;
import "../../widgets/dialogs.dart";
import "../activity/activities.dart";
import "../activity/activity.dart" show Run;
import "../activity/label.dart" show ActivityGroup;
import "code_block.dart";
import "reply_style.dart";
import "selection_html.dart";
import "shell_run.dart";

/// Renders a single message. The bubble holds what the model said; thinking
/// and tool runs sit above it as labels, in the order they happened.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.chatId,
    required this.message,
    this.avatar,
    this.entoli = false,
    this.isWaiting = false,
    this.waitingNotice,
    this.waitingStatus,
    this.shellOutput,
    this.threads,
    this.onThreadStep,
    this.onDelete,
    this.onEdit,
    this.onRegenerate,
    this.onSpeak,
    this.isSpeaking = false,
    this.onTapLink,
    this.steerKey,
  });

  /// Which chat's `resources/` the attachments are read back from.
  final String chatId;

  final Message message;

  /// The author's profile picture, drawn beside the name where the message
  /// names an addressed member — the page's bytes are the whole gate. Bytes in
  /// hand — the page resolves them — so the bubble stays a
  /// StatelessWidget-and-State over what it is told.
  final Uint8List? avatar;

  /// The reply is in a section of the conversation where Omada is on: an
  /// unnamed reply is the main agent's, and says so — "Entoli" — the same
  /// slot a member's name uses. Direct chats and off-sections show nothing.
  final bool entoli;

  /// This message is the one being generated right now.
  final bool isWaiting;

  /// Trouble reported while the turn is still running, e.g. a retry after a
  /// rate limit. Shown in red beside the spinner.
  final String? waitingNotice;

  /// What the turn is doing — "Thinking", "Reading the prompt · 43%". Beside
  /// the spinner like [waitingNotice] and in the ordinary muted colour, because
  /// it is the answer to "is this alive" rather than a problem.
  final String? waitingStatus;

  /// What a running command has printed so far, shown as a live block under
  /// the tool label (an agent's `bash` call) or under the spinner (the user's
  /// own `!` command, whose reply is still empty). Trailing state like
  /// [waitingStatus]: it is gone the moment the call's result lands, which is
  /// the point at which the conversation's own output takes over — the label's
  /// drawer, or the `!` bubble.
  final String? shellOutput;

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

  /// Read this message out, or stop reading it. Null where there is no speech
  /// model to read it with.
  final VoidCallback? onSpeak;

  /// This is the message being read out. The button then offers to stop, and
  /// the row stays up while it reads — otherwise stopping would mean going
  /// looking for the button that started it.
  final bool isSpeaking;

  /// Open a link tapped in the rendered markdown. Receives the `href`.
  final ValueChanged<String>? onTapLink;

  /// The key for the bubble of a steer read into this reply, by the steer's
  /// id: what the chapter rail finds it by.
  final GlobalKey Function(String id)? steerKey;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hovered = false;
  bool _tapped = false;
  Offset? _pressedAt;

  /// Uncovering the icons redraws the icons. A `setState` would rebuild the
  /// whole message — every label re-parsing its call's arguments — to change
  /// one opacity, and the pointer crosses a message twice on its way past.
  final ValueNotifier<bool> _shown = ValueNotifier(false);

  /// One container delegate for the whole message, held across rebuilds: a
  /// streamed delta rebuilds the message every frame, and a delegate per
  /// build would drop the selection under the drag that is making it. See
  /// [_RenderedSelection] for what it answers.
  _RenderedSelection? _selection;

  void _show({bool? hovered, bool? tapped}) {
    _hovered = hovered ?? _hovered;
    _tapped = tapped ?? _tapped;
    _shown.value = _hovered || _tapped;
  }

  @override
  void initState() {
    super.initState();
    _readCommand();
  }

  @override
  void didUpdateWidget(MessageBubble old) {
    super.didUpdateWidget(old);
    if (old.message.id != widget.message.id) _readCommand();
  }

  @override
  void dispose() {
    _shown.dispose();
    _selection?.dispose();
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

  Future<void> _copy() => copyToClipboard(
        context,
        // What the message reads, not what conv.jsonl keeps: the formatted
        // text is what a reader would paste into another document. Raw
        // markdown is the button beside it.
        formattedTextOf(widget.message.plainText),
        html: htmlClipboardDocument(formattedHtmlOf(widget.message.plainText)),
        said: "Message copied",
      );

  /// What Ctrl+C and the selection menu's Copy write: the selection as text
  /// and as HTML, both read before anything is awaited, since the menu clears
  /// the selection as soon as this returns.
  Future<void> _copySelection() async {
    final selection = _selection;
    final plain = selection?.getSelectedContent()?.plainText;
    if (selection == null || plain == null) return;
    final html = selection.selectedHtml(context.findRenderObject(), widget.message.plainText);
    await setRichClipboard(plain: plain, html: htmlClipboardDocument(html ?? escapeHtml(plain)));
  }

  /// The selection's menu, the framework's own with Copy swapped for
  /// [_copySelection]; what follows a copy is what the framework's does.
  Widget _selectionMenu(BuildContext context, SelectableRegionState region) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: region.contextMenuAnchors,
        buttonItems: [
          for (final item in region.contextMenuButtonItems)
            if (item.type == ContextMenuButtonType.copy)
              item.copyWith(onPressed: () {
                unawaited(_copySelection());
                switch (defaultTargetPlatform) {
                  case TargetPlatform.android || TargetPlatform.fuchsia:
                    region.clearSelection();
                  case TargetPlatform.iOS:
                    region.hideToolbar(false);
                  case TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows:
                    region.hideToolbar();
                }
              })
            else
              item,
        ],
      );

  Future<void> _copyRaw() =>
      copyToClipboard(context, widget.message.plainText, said: "Markdown copied");

  /// The turn's last round failed, which is what Retry answers: within a round
  /// nothing follows an error, so a turn that ended on one has it trailing,
  /// and a carried-on round has appended past it.
  bool get _hasError => widget.message.parts.lastOrNull is ErrorPart;

  /// The command a `!` message runs, or null where it is prose. Read off the
  /// text rather than stored: `conv.jsonl` keeps the message as typed, so the
  /// bubble and the backend answer this from the same string.
  ///
  /// Parsed once and kept, the way an asked question's are: every visible
  /// message is rebuilt on every streamed delta, and what a prompt says does not
  /// change under one — an edit is a new message, with a new id.
  String? _command;

  /// Whether this prompt runs a callback (`/compact`) rather than asking for
  /// anything said. Read beside [_command], for the same reasons.
  bool _wired = false;

  void _readCommand() {
    final user = widget.message.role == MessageRole.user;
    final text = widget.message.plainText;
    _command = user ? shellBypassCommand(text) : null;
    _wired = user && wiredSkillFromText(text) != null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = widget.message.role == MessageRole.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // The reply has no tint behind it and no name over it: it is the page
    // rather than something said to one side of it, and nothing else in the
    // conversation is drawn full width and unbubbled — so both were the layout
    // said a second time. The other three keep a name, which is what makes the
    // prompt something said and a tool run something reported.
    final (name, bg) = switch (widget.message.role) {
      // A command the user ran is not something they said, so it does not get
      // the colour the things they said are in.
      MessageRole.user => (
          "You",
          _command == null && !_wired
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest
        ),
      MessageRole.assistant =>
        (widget.message.author ?? (widget.entoli ? "Entoli" : null), null),
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
                  if (name != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // The member's face where there is one, beside the
                          // name — the page's bytes are the whole gate already:
                          // they arrive only where the label names a member,
                          // and a prompt's "You" is never one.
                          if (widget.avatar != null) ...[
                            AgentPictureImage(bytes: widget.avatar, size: 18),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              name,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // One region for the whole reply, so a drag runs from the
                  // first paragraph to the last rather than stopping at the
                  // bubble — or the tool label — it started in. The container
                  // inside is the one selection container between that region
                  // and the fragments, so what a selection copies is decided
                  // in one place, [_RenderedSelection] below; the labels
                  // inside stay disabled.
                  //
                  // The region's copy writes plain text, so Ctrl+C is taken
                  // over here — the region's copy action defers to one above
                  // it — and the menu's Copy in `_selectionMenu`.
                  Actions(
                    actions: {
                      CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
                        onInvoke: (_) => unawaited(_copySelection()),
                      ),
                    },
                    child: SelectionArea(
                      contextMenuBuilder: _selectionMenu,
                      child: SelectionContainer(
                        delegate: _selection ??= _RenderedSelection(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: align,
                          children: _rows(context, bg),
                        ),
                      ),
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
              _step(Icons.chevron_left, "Previous thread", -1),
              _step(Icons.chevron_right, "Next thread", 1),
            ],
            if (widget.message.hasText) ...[
              ActionIcon(
                  icon: Icons.copy_outlined, tooltip: "Copy message", onPressed: _copy),
              ActionIcon(
                  icon: Icons.code,
                  tooltip: "Copy raw markdown",
                  onPressed: _copyRaw),
            ],
            if (widget.onSpeak != null)
              ActionIcon(
                icon: widget.isSpeaking
                    ? Icons.stop_circle_outlined
                    : Icons.volume_up_outlined,
                tooltip: widget.isSpeaking ? "Stop reading" : "Read aloud",
                onPressed: widget.onSpeak!,
              ),
            if (widget.onDelete != null)
              ActionIcon(
                  icon: Icons.delete_outline, tooltip: "Delete thread", onPressed: _delete),
            if (widget.onEdit != null)
              ActionIcon(icon: Icons.edit_outlined, tooltip: "Edit", onPressed: _edit),
            if (widget.onRegenerate != null)
              ActionIcon(
                  icon: Icons.refresh,
                  tooltip: "Regenerate",
                  onPressed: widget.onRegenerate!),
          ],
        ),
        // Kept whether or not there is anything to show, so a message does not
        // shift under the pointer the moment the actions appear.
        builder: (context, shown, child) {
          final up = shown || widget.isSpeaking;
          return SizedBox(
            height: ActionIcon.height,
            child: AnimatedOpacity(
              opacity: up ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: IgnorePointer(ignoring: !up, child: child),
            ),
          );
        },
      );

  /// How many threads were written where this message is, and which of them it
  /// is. A message with none is a thread of one, and the only one.
  int get _threads => widget.threads?.length ?? 1;
  int get _thread => widget.threads?.indexOf(widget.message.id) ?? 0;

  /// An arrow to the thread [step] along, dead at either end of the list and
  /// while nothing is listening — the row is uncovered during a turn, when
  /// moving between threads is refused.
  Widget _step(IconData icon, String tooltip, int step) {
    final onStep = widget.onThreadStep;
    final to = _thread + step;
    return ActionIcon(
      icon: icon,
      tooltip: tooltip,
      onPressed:
          onStep == null || to < 0 || to >= _threads ? null : () => onStep(step),
    );
  }

  /// The message split the way it reads: everything the model did on labels of
  /// its own, everything it said in a bubble, in the order it happened.
  List<Widget> _rows(BuildContext context, Color? bg) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    final spoken = <Widget>[];
    // A prompt's files head its bubble; a reply's are drawn where they were
    // made, below the call that made them.
    final isUser = widget.message.role == MessageRole.user;
    var files = isUser ? widget.message.files.toList() : <FilePart>[];

    final parts = widget.message.parts;
    // The part a running turn is working on. A turn is always working on its
    // last one, so this is what "live" means for anything drawn from the loop
    // below — the thinking block that has not closed, and the text still being
    // written.
    final liveAt = widget.isWaiting && parts.isNotEmpty ? parts.length - 1 : null;
    // A running turn shows one of two things and never both: a caret at the end
    // of the text being written, or a spinner when there is no such text to put
    // one on. `hasText` was not that decision on its own — it ignores
    // whitespace, so a first flush of it drew a spinner beside a caret.
    final carets = liveAt != null && parts[liveAt] is TextPart;

    Widget said(String text, {bool isError = false, bool caret = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: MessageText(
            text: text,
            isError: isError,
            isWaiting: widget.isWaiting,
            caret: caret,
            onTapLink: widget.onTapLink,
          ),
        );

    final results = widget.message.toolResults;
    final calls = {
      for (final part in widget.message.parts.whereType<ToolCallPart>()) part.toolCall.id,
    };

    // Trailing state, not parts: they belong under the last thing said.
    final extras = <Widget>[
      if (widget.isWaiting && !carets && !widget.message.hasText)
        _Spinner(
          color: theme.colorScheme.onSurfaceVariant,
          notice: widget.waitingNotice,
          status: widget.waitingStatus,
        ),
      // Trailing like the spinner above: gone the moment the call's result
      // lands or the turn ends, since the conversation's own output is what
      // takes over from there. Not gated on [isWaiting], which is the last
      // message's: a message said after this reply would take the block.
      if (widget.shellOutput != null)
        LiveShellOutput(code: widget.shellOutput!),
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

    // A run of consecutive activities none of which is important, gathered so
    // two or more of them can sit behind one centered "Expand activities"
    // toggle rather than stacking above the reply. Text, errors and files are
    // not activities and break a run too. A `ToolResultPart` whose call is
    // present is drawn by that call's label, so it neither joins nor breaks one.
    List<Widget> gathered = [];
    var runStart = -1;

    bool isLive(int i) => i == liveAt;

    void flushRun() {
      if (gathered.isEmpty) return;
      closeBubble();
      if (gathered.length >= 2) {
        rows.add(ActivityGroup(key: ValueKey(runStart), children: gathered));
      } else {
        rows.addAll(gathered);
      }
      gathered = [];
      runStart = -1;
    }

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      switch (part) {
        case ToolResultPart(:final result) when calls.contains(result.callId):
          // Drawn by the call it answers.
          continue;
        case ReasoningPart() ||
              ToolCallPart() ||
              ToolResultPart() ||
              InstructionsPart() ||
              ApprovalPart() ||
              ArtifactPart() ||
              SkillInstallPart():
          final activity = activityFor(part)!;
          final run = _runOf(part, i, results, live: isLive(i));
          // What breaks a run of activities: one important of itself, the
          // call the live turn is on, and a run that came back failed.
          final important = activity.important(run) ||
              (isLive(i) && part is ToolCallPart) ||
              (run.result?.returnCode ?? 0) != 0;
          final label = _label(activity.build(run));
          if (important) {
            flushRun();
            rows.add(label);
            break;
          }
          if (runStart == -1) runStart = i;
          gathered.add(label);
        case FilePart():
          if (isUser) continue;
          flushRun();
          closeBubble();
          rows.add(AttachmentStrip(children: [
            AttachmentChip.sent(part, chatId: widget.chatId, size: 256),
          ]));
        case ShellRunPart():
          // Not a label: a command the user ran is the answer to their message
          // rather than something the turn did on its way to one.
          flushRun();
          closeBubble();
          rows.add(ShellRunBubble(run: part));
        case TextPart(:final text):
          // Text with a tool call under it stopped arriving before the call
          // started, so a caret there would point at nothing while the label
          // below it is what is busy.
          flushRun();
          final command = _command;
          spoken.add(command == null
              ? said(text, caret: i == liveAt)
              : ShellCommandText(command: command));
        case ErrorPart(:final message):
          flushRun();
          spoken.add(said("Error: $message", isError: true));
        case SteerPart(:final message):
          // What the user said while the turn ran, where the turn read it:
          // their bubble, with the reply carrying on under it.
          flushRun();
          closeBubble();
          rows.add(Align(
            key: widget.steerKey?.call(message.id),
            alignment: Alignment.centerRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4, bottom: 2),
                  child: Text(
                    "You, while it worked",
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                _bubble(context, theme.colorScheme.primaryContainer,
                    said: [if (message.hasText) said(message.plainText)],
                    files: message.files.toList(),
                    trailing: const []),
              ],
            ),
          ));
      }
    }
    flushRun();
    closeBubble(trailing: extras);
    return rows;
  }

  /// A label sits inside the message's selection region but is not part of what
  /// the message says, so dragging past one must not put "Thought for 12
  /// seconds" on the clipboard. Its own drawer is a route and so is outside the
  /// region already.
  Widget _label(Widget child) => SelectionContainer.disabled(child: child);

  /// What [part], at [at], is drawn from as an activity. [live] is the part
  /// the turn is on.
  Run _runOf(MessagePart part, int at, Map<String, ToolResult> results,
          {required bool live}) =>
      switch (part) {
        ToolCallPart(:final toolCall) => Run(
            chatId: widget.chatId,
            callId: toolCall.id,
            call: toolCall,
            result: results[toolCall.id],
            going: live && widget.message.hasText,
          ),
        ToolResultPart(:final result) =>
          Run(chatId: widget.chatId, callId: result.callId, result: result),
        ApprovalPart(:final approvalId) => Run(
            chatId: widget.chatId, part: part, result: results[approvalId]),
        ReasoningPart(:final durationMs) => Run(
            chatId: widget.chatId,
            part: part,
            at: at,
            going: live && durationMs == null),
        _ => Run(chatId: widget.chatId, part: part, at: at),
      };

  Widget _bubble(
    BuildContext context,
    Color? bg, {
    required List<Widget> said,
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
        if (bg == null)
          ...said
        else
          Theme(
            data: onFillTheme(Theme.of(context), bg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: said,
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
///
/// Public because two homes render reply text now: the bubble's, and the
/// compaction summary beneath its divider — the same encoding, the same
/// rendering, whether the model wrote it as a reply or as a summary.
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.isError,
    required this.isWaiting,
    required this.caret,
    this.onTapLink,
  });

  final String text;
  final bool isError;
  final bool isWaiting;

  /// This is the text being written right now, so it ends in a caret.
  final bool caret;

  final ValueChanged<String>? onTapLink;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  MarkdownStyleSheet? _styleSheet;

  /// Raw while the reply streams or when it is an error: there is no markdown
  /// to render yet, and an error is not the model's prose.
  bool get _rendered => !widget.isWaiting && !widget.isError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _styleSheet = replyStyleSheet(Theme.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_rendered) {
      final style = widget.isError
          ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)
          : theme.textTheme.bodyMedium;
      // Rich only where there is a caret to put in it. Folding both into one
      // `Text.rich` reads tidier and costs the plain string: `Text.data` is
      // null for a span, so an error would stop being something `find.text`
      // and `.data` can reach, for no gain to anything on screen.
      if (!widget.caret) return Text(widget.text, style: style);
      return Text.rich(
        TextSpan(
          text: widget.text,
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: StreamingCaret(
                color: theme.colorScheme.primary,
                // A bare rectangle inside the span rather than text in it, so
                // nothing else gives it a height.
                height: style?.fontSize ?? 14,
              ),
            ),
          ],
        ),
        style: style,
      );
    }
    // No `selectable`, and no container of its own: the fragments register
    // with the message's own container above, which is what makes a drag run
    // from the first paragraph to the last — `selectable` builds a
    // `SelectableText` per element, each a selection region to itself, which
    // is what made a selection stop at the paragraph it started in. The
    // bullets are chrome, like a code block's bar: on screen, but not part of
    // what a drag picks up, so what a selection copies reads as the list's
    // items rather than `•Item`.
    return MarkdownBody(
      data: widget.text,
      styleSheet: _styleSheet,
      builders: codeBlockBuilders,
      bulletBuilder: (parameters) => SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            "•",
            style: _styleSheet?.listBullet ?? Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ),
      onTapLink: (text, href, title) {
        if (href != null) widget.onTapLink?.call(href);
      },
    );
  }
}

/// What a selection of the message copies as: the rendered text, the words on
/// screen. One container between the region and every fragment — heading,
/// paragraph, list item, code block — so the drag, the handles and the edges
/// are the framework's own, and copy answers from the same fragments the
/// highlight is drawn from.
///
/// The one override is what Ctrl+C, the context menu and the mobile toolbar
/// all read. The base answer concatenates the fragments with nothing between
/// them, and a heading and its paragraph are separate fragments because the
/// gaps live in widgets, not in text — so blocks are joined with a newline
/// where they do not share a line. A fragment with no selection, and a
/// selection collapsed to a point, answer nothing: an empty clipboard is a
/// copy that reports success over nothing.
///
/// [selectedHtml] is the same selection formatted, the clipboard's other half.
class _RenderedSelection extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    for (final (selectable: _, :selected, :sameLine, box: _) in _selected()) {
      if (buffer.isNotEmpty && !sameLine) buffer.write("\n");
      buffer.write(selected);
    }
    if (buffer.isEmpty) return null;
    return SelectedContent(plainText: buffer.toString());
  }

  /// The selection as an HTML fragment, read from the paragraphs under [root]
  /// and the [markdown] they were rendered from; null where nothing is.
  String? selectedHtml(RenderObject? root, String markdown) {
    final paragraphs = paragraphsUnder(root);
    final pieces = <SelectedPiece>[];
    for (final (:selectable, :selected, :sameLine, :box) in _selected()) {
      final range = selectable.getSelection();
      final paragraph =
          range == null ? null : paragraphOf(selectable, paragraphs, selected, range);
      final start = range == null ? 0 : math.min(range.startOffset, range.endOffset);
      pieces.add(SelectedPiece(
        text: selected,
        paragraph: paragraph,
        start: start,
        end: start + selected.length,
        sameLine: pieces.isNotEmpty && sameLine,
        // A container of its own — a code block's scroll — drawn in the code
        // face is a code block.
        monospace: paragraph == null &&
            paragraphs.any((p) =>
                p.attached &&
                box.contains(MatrixUtils.transformRect(
                        p.getTransformTo(null), Offset.zero & p.size)
                    .center) &&
                isMonospace(p)),
      ));
    }
    if (pieces.isEmpty) return null;
    return selectionHtml(pieces, RenderedOutline.of(markdown));
  }

  /// Each selectable with something selected, in order, and whether it shares
  /// a rendered line with what went before: one that does not overlap the box
  /// selected so far vertically is a block of its own.
  List<({Selectable selectable, String selected, bool sameLine, Rect box})> _selected() {
    final found = <({Selectable selectable, String selected, bool sameLine, Rect box})>[];
    Rect? covered;
    for (final Selectable selectable in selectables) {
      final SelectedContent? selected = selectable.getSelectedContent();
      if (selected == null) continue;
      final transform = selectable.getTransformTo(null);
      final Rect line = MatrixUtils.transformRect(transform, selectable.boundingBoxes.first);
      final sameLine =
          covered != null && line.top <= covered.bottom && line.bottom >= covered.top;
      final Rect box = MatrixUtils.transformRect(
        transform,
        selectable.boundingBoxes.reduce((a, b) => a.expandToInclude(b)),
      );
      found.add((selectable: selectable, selected: selected.plainText, sameLine: sameLine, box: box));
      covered = covered?.expandToInclude(line) ?? line;
    }
    return found;
  }
}

/// Sits at the end of the text while it is still arriving. [_Spinner] answers
/// for a reply that has said nothing yet; once there are words, the thing worth
/// pointing at is where the next one goes.
///
/// It fades rather than blinking on and off: a hard blink beside prose that is
/// itself growing reads as two things moving, and this has to be noticed
/// without being watched.
class StreamingCaret extends StatefulWidget {
  const StreamingCaret({super.key, required this.color, required this.height});

  final Color color;
  final double height;

  @override
  State<StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  /// Built once beside the controller rather than in `build`: a streaming reply
  /// rebuilds on every coalesced delta, and a fresh `Animation` each time makes
  /// the render object drop and re-add its listener for no change.
  ///
  /// It fades to 0.2 rather than to nothing, which also keeps the opacity layer
  /// a repaint boundary throughout — at zero it stops being one twice a cycle
  /// and takes the paragraph above it into the repaint.
  late final _opacity = _pulse.drive(Tween(begin: 1.0, end: 0.2));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: Container(
          // Beside the last word rather than against it.
          margin: const EdgeInsets.only(left: 2),
          width: 2,
          height: widget.height,
          color: widget.color,
        ),
      );
}

/// Stands in for the reply until the first text arrives.
///
/// [status] is what the turn is doing and [notice] is what has gone wrong with
/// it, and both sit on this one row. Trouble wins when there is any: a retry
/// after a rate limit is what the reader needs, and "Thinking" beside it would
/// be the turn claiming to be fine.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.color, this.notice, this.status});
  final Color color;
  final String? notice;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = notice ?? status;
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
          if (said != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                said,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: notice != null ? theme.colorScheme.error : color,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

