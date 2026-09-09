import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
// `SelectedContent`, which material does not re-export.
import "package:flutter/rendering.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:markdown/markdown.dart" as md;

import "../../../domain/ask.dart";
import "../../../domain/models.dart";
import "../../../domain/shell.dart";
import "../../widgets/action_icon.dart";
import "../../widgets/attachment_chip.dart";
import "../../widgets/dialogs.dart";
import "activity_label.dart";
import "code_block.dart";
import "reply_style.dart";
import "shell_run.dart";

/// Renders a single message. The bubble holds what the model said; thinking
/// and tool runs sit above it as labels, in the order they happened.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.chatId,
    required this.message,
    this.author,
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
  });

  /// Which chat's `resources/` the attachments are read back from.
  final String chatId;

  final Message message;

  /// The addressed member to name over the reply, the way a prompt shows
  /// "You". Null draws nothing. See [Message.author].
  final String? author;

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
        said: "Message copied",
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
  /// Parsed once and kept, the way an `AskLabel`'s questions are: every visible
  /// message is rebuilt on every streamed delta, and what a prompt says does not
  /// change under one — an edit is a new message, with a new id.
  String? _command;

  void _readCommand() => _command = widget.message.role == MessageRole.user
      ? shellBypassCommand(widget.message.plainText)
      : null;

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
          _command == null
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest
        ),
      MessageRole.assistant =>
        (widget.author ?? (widget.entoli ? "Entoli" : null), null),
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
                      child: Text(
                        name,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  // One region for the whole reply, so a drag runs from the
                  // first paragraph to the last rather than stopping at the
                  // bubble — or the tool label — it started in. The container
                  // inside is the one selection container between that region
                  // and the fragments, so what a selection copies is decided
                  // in one place, [_RenderedSelection] below; the labels
                  // inside stay disabled.
                  SelectionArea(
                    child: SelectionContainer(
                      delegate: _selection ??= _RenderedSelection(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: align,
                        children: _rows(context, bg),
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
    var files = widget.message.files.toList();

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
          child: _MessageText(
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
      // takes over from there.
      if (widget.isWaiting && widget.shellOutput != null)
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

    // A run of consecutive non-important activity labels, gathered so two or
    // more of them can sit behind one centered "Expand activities" toggle
    // rather than stacking above the reply. What is important and so breaks a
    // run: an artifact button, a failed tool run, an `ask_user` question, and
    // the live label a running turn is working on. Text, errors and files are
    // not labels and break a run too. A `ToolResultPart` whose call is present
    // is drawn by that call's label, so it neither joins nor breaks a run.
    List<Widget> run = [];
    var runStart = -1;

    bool isLive(int i) => i == liveAt;
    bool failedResult(String? callId) =>
        callId != null && (results[callId]?.returnCode ?? 0) != 0;

    void flushRun() {
      if (run.isEmpty) return;
      closeBubble();
      if (run.length >= 2) {
        rows.add(ActivityGroup(key: ValueKey(runStart), children: run));
      } else {
        rows.addAll(run);
      }
      run = [];
      runStart = -1;
    }

    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      switch (part) {
        case ReasoningPart():
          // The block being written right now is what the turn is busy with.
          if (isLive(i) && part.durationMs == null) {
            flushRun();
            rows.add(_label(ThinkingLabel(part: part, isLive: true)));
            break;
          }
          if (runStart == -1) runStart = i;
          run.add(_label(ThinkingLabel(part: part)));
        case ToolCallPart(:final toolCall):
          // A question to the user is important; so is a live call and a call
          // that came back non-zero. The rest join the run.
          if (toolCall.name == askToolName || isLive(i) || failedResult(toolCall.id)) {
            flushRun();
            rows.add(_label(switch (toolCall.name) {
              askToolName => AskLabel(call: toolCall, result: results[toolCall.id]),
              "task" => TaskLabel(call: toolCall, result: results[toolCall.id]),
              "websearch" => WebSearchLabel(call: toolCall, result: results[toolCall.id]),
              "webfetch" => WebFetchLabel(call: toolCall, result: results[toolCall.id]),
              _ => ToolLabel(call: toolCall, result: results[toolCall.id],
                  running: isLive(i) && widget.message.hasText),
            }));
            break;
          }
          if (runStart == -1) runStart = i;
          run.add(_label(switch (toolCall.name) {
            "task" => TaskLabel(call: toolCall, result: results[toolCall.id]),
            "websearch" => WebSearchLabel(call: toolCall, result: results[toolCall.id]),
            "webfetch" => WebFetchLabel(call: toolCall, result: results[toolCall.id]),
            _ => DiffTextLabel.forRun(toolCall, results[toolCall.id]) ??
                ToolLabel(call: toolCall, result: results[toolCall.id]),
          }));
        case ToolResultPart(:final result):
          // Already drawn by the call it answers, unless the call is gone. An
          // orphaned failed result is important; an orphaned success joins the
          // run for the same reason any other success would.
          if (calls.contains(result.callId)) continue;
          if (result.returnCode != 0) {
            flushRun();
            rows.add(_label(ToolLabel(result: result)));
          } else {
            if (runStart == -1) runStart = i;
            run.add(_label(ToolLabel(result: result)));
          }
        case FilePart():
          continue;
        case ArtifactPart(:final artifactId, :final entryFile, :final title):
          flushRun();
          rows.add(ArtifactLabel(
            chatId: widget.chatId,
            artifactId: artifactId,
            entryFile: entryFile,
            title: title,
          ));
        case SkillInstallPart(:final installId, :final title):
          flushRun();
          rows.add(SkillInstallLabel(
            chatId: widget.chatId,
            installId: installId,
            title: title,
          ));
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
        ...said,
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
  State<_MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<_MessageText> {
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
    // is what made a selection stop at the paragraph it started in.
    return MarkdownBody(
      data: widget.text,
      styleSheet: _styleSheet,
      builders: codeBlockBuilders,
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
class _RenderedSelection extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    // The union of what has been selected so far, in container coordinates:
    // a fragment that does not overlap it vertically is on a rendered line of
    // its own, and one newline separates it from what went before.
    Rect? covered;
    for (final Selectable selectable in selectables) {
      final SelectedContent? selected = selectable.getSelectedContent();
      if (selected == null) continue;
      final Rect box = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        selectable.boundingBoxes.first,
      );
      if (buffer.isNotEmpty &&
          covered != null &&
          (box.top > covered.bottom || box.bottom < covered.top)) {
        buffer.write("\n");
      }
      buffer.write(selected.plainText);
      covered = covered?.expandToInclude(box) ?? box;
    }
    if (buffer.isEmpty) return null;
    return SelectedContent(plainText: buffer.toString());
  }
}

/// What a message's markdown reads once rendered: the formatted text the copy
/// button takes, where the selection's copy answers from what is on screen.
/// Inline styles fall away, links by the words they carry, blocks as lines.
///
/// Parsed with the same document grammar the renderer uses, so the two cannot
/// disagree about what a fence or a list is.
String formattedTextOf(String markdown) {
  final buffer = StringBuffer();
  final visitor = _FormattedTextVisitor(buffer);
  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  for (final node in document.parseLines(markdown.split("\n"))) {
    node.accept(visitor);
  }
  return buffer.toString().trimRight();
}

class _FormattedTextVisitor implements md.NodeVisitor {
  _FormattedTextVisitor(this.buffer);

  final StringBuffer buffer;

  /// A paragraph or heading writes into a fresh line, so the next one starts
  /// below it rather than glued to its last word.
  bool _needsBreak = false;

  void _break() {
    if (buffer.isEmpty) return;
    if (_needsBreak) buffer.write("\n");
    _needsBreak = false;
  }

  @override
  bool visitElementBefore(md.Element element) {
    switch (element.tag) {
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6" || "p" || "li" || "hr":
        _break();
      case "br":
        buffer.write("\n");
        return false;
    }
    // The children carry the content; nothing is written for the element
    // itself, so there is nothing to stand in for it.
    return true;
  }

  @override
  void visitText(md.Text text) {
    _break();
    buffer.write(text.text);
  }

  @override
  void visitElementAfter(md.Element element) {
    switch (element.tag) {
      case "h1" || "h2" || "h3" || "h4" || "h5" || "h6" || "p" || "li":
        _needsBreak = true;
      case "pre":
        // The fenced code the parser kept, not the styling round it.
        _break();
        buffer.write(element.textContent.trimRight());
        _needsBreak = true;
    }
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

