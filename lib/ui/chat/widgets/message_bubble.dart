import "dart:async";

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/agent_face.dart";
import "../../../domain/bot_avatar/pose.dart" show BotMood;
import "../../../domain/models.dart";
import "../../../domain/quote.dart";
import "../../../app/settings/spec.dart" show WidgetReader;
import "../../../app/transcript/activity.dart" show activityCatalogProvider;
import "../../../app/transcript/message.dart";
import "../../../app/transcript/transcript.dart"
    show DeleteQuestion, MessageActions;
import "../../widgets/action_icon.dart";
import "../../widgets/agent_picture.dart" show AgentPictureImage;
import "../../widgets/attachment_chip.dart";
import "../../theme.dart" show onFillTheme;
import "../../widgets/dialogs.dart";
import "../../widgets/prompt_field.dart";
import "../../selection.dart" show selectedProjectProvider;
import "../activity/activity.dart" show ActivityNodeView;
import "../activity/label.dart" show ActivityGroup;
import "../../selection/copy_format.dart" show replyContentOf;
import "../../selection/rich_selection_area.dart";
import "message_text.dart";
import "reaction_button.dart";
import "shell_run.dart";

/// Renders a single message as the core lays it out (`MessageLayout`). The bubble holds what the model said; thinking
/// and tool runs sit above it as labels, in the order they happened.
class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({
    super.key,
    required this.chatId,
    required this.message,
    this.avatar,
    this.isWaiting = false,
    this.latest = false,
    this.waitingNotice,
    this.waitingStatus,
    this.shellOutput,
    this.actions,
    this.onSpeak,
    this.isSpeaking = false,
    this.onTapLink,
    this.onReply,
    this.reactions = const [],
    this.steerKey,
  });

  /// Which chat's `resources/` the attachments are read back from.
  final String chatId;

  final Message message;

  /// The author's face, drawn beside the name where the message names an
  /// addressed member — the page's answer is the whole gate. In hand — the
  /// page resolves it — so the bubble stays a StatelessWidget-and-State over
  /// what it is told. A Bot Avatar is live: it thinks while the reply is
  /// being written and idles once it is done, follows the pointer, and is
  /// happy for a while when tapped. Rows the list keeps built off screen
  /// cost nothing, since an avatar that is not painted stops its ticker.
  final AgentFace? avatar;

  /// This message is the one being generated right now.
  final bool isWaiting;

  /// The newest message of the thread: its author's Bot Avatar is the one
  /// live in the conversation, the rest drawing stills — one avatar moving
  /// per chat rather than one per reply. A tap still wakes any of them.
  final bool latest;

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

  /// What can be done to the message, and when: threads, delete, edit,
  /// regenerate, react. Null is a transcript shown read-only.
  final MessageActions? actions;

  /// Read this message out, or stop reading it. Null where there is no speech
  /// model to read it with.
  final VoidCallback? onSpeak;

  /// This is the message being read out. The button then offers to stop, and
  /// the row stays up while it reads — otherwise stopping would mean going
  /// looking for the button that started it.
  final bool isSpeaking;

  /// Open a link tapped in the rendered markdown. Receives the `href`.
  final ValueChanged<String>? onTapLink;

  /// Answer a passage selected in this message: the selection menu's Reply.
  /// A reply's quote carries its author's handle, so the answer is
  /// addressed to them.
  final ValueChanged<Quote>? onReply;

  /// The emoji this message has been reacted with, drawn at the end of its
  /// action row whether or not the actions are showing.
  final List<String> reactions;

  /// The key for the bubble of a steer read into this reply, by the steer's
  /// id: what the chapter rail finds it by.
  final GlobalKey Function(String id)? steerKey;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
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
  void didUpdateWidget(MessageBubble old) {
    super.didUpdateWidget(old);
    if (!identical(old.message, widget.message)) _layout = _layoutOf();
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  /// On a page of its own, the composer's field: a message is often long, and
  /// the `/` and `@` it was written with complete here the way they did there.
  Future<void> _edit() async {
    final at = ref.read(selectedProjectProvider);
    final edited = await PromptPage.open(
      context,
      title: "Edit message",
      text: widget.message.plainText,
      hint: "Message",
      project: at.project,
      device: at.device,
      confirmLabel: "Send",
    );
    final text = edited?.trim() ?? "";
    // A blank message says nothing, so sending one is not what was meant.
    await _can.edit(text);
  }

  Future<void> _delete() async {
    final actions = _can;
    final ok = await confirm(
      context,
      title: DeleteQuestion.title,
      message: actions.deleteQuestion.message,
      confirmLabel: DeleteQuestion.confirmLabel,
      destructive: true,
    );
    if (ok) await actions.delete();
  }

  /// What the message reads, not what conv.jsonl keeps: the formatted
  /// text is what a reader would paste into another document, its formulas
  /// drawn as they are here. Raw markdown is the button beside it.
  Future<void> _copy() async {
    final content = await replyContentOf(
      widget.message.plainText,
      context.findRenderObject(),
    );
    if (!mounted) return;
    await copyToClipboard(
      context,
      content.plain,
      html: content.html,
      said: "Message copied",
    );
  }

  Future<void> _copyRaw() => copyToClipboard(
    context,
    widget.message.plainText,
    said: "Markdown copied",
  );

  /// The core's layout of the message, read again when it is another
  /// message: what a prompt says does not change under a delta — an edit is
  /// a new message, with a new id — so its command is parsed once.
  late MessageLayout _layout = _layoutOf();

  MessageLayout _layoutOf() => MessageLayout(
    widget.message,
    chatId: widget.chatId,
    catalog: ref.read(activityCatalogProvider),
  );

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
    final speaker = _layout.speaker;
    final name = speaker.name;
    final bg = _fillOf(theme, speaker.tint);

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
                if (from == null ||
                    (event.position - from).distance > kTouchSlop) {
                  return;
                }
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
                            AgentPictureImage(
                              face: widget.avatar,
                              size: 45,
                              animate: widget.latest,
                              reactToTap: true,
                              mood: widget.isWaiting
                                  ? BotMood.thinking
                                  : BotMood.idle,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              name,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // One area for the whole reply, so a drag runs from the
                  // first paragraph to the last rather than stopping at the
                  // bubble — or the tool label — it started in; the labels
                  // inside stay disabled. What it copies is the area's own
                  // business: see `RichSelectionArea`.
                  RichSelectionArea(
                    markdown: () => widget.message.plainText,
                    onReply: widget.onReply == null
                        ? null
                        : (text) => widget.onReply!(
                            Quote(text, handle: widget.message.author),
                          ),
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
        if (_can.showsThreads) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _can.threadLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _step(Icons.chevron_left, "Previous thread", -1),
          _step(Icons.chevron_right, "Next thread", 1),
        ],
        if (widget.message.hasText) ...[
          ActionIcon(
            icon: Icons.copy_outlined,
            tooltip: "Copy message",
            onPressed: _copy,
          ),
          ActionIcon(
            icon: Icons.code,
            tooltip: "Copy raw markdown",
            onPressed: _copyRaw,
          ),
        ],
        if (_can.canReact)
          ReactionButton(onReact: _can.react, chosen: widget.reactions),
        if (widget.onSpeak != null)
          ActionIcon(
            icon: widget.isSpeaking
                ? Icons.stop_circle_outlined
                : Icons.volume_up_outlined,
            tooltip: widget.isSpeaking ? "Stop reading" : "Read aloud",
            onPressed: widget.onSpeak!,
          ),
        if (_can.canDelete)
          ActionIcon(
            icon: Icons.delete_outline,
            tooltip: "Delete thread",
            onPressed: _delete,
          ),
        if (_can.canEdit)
          ActionIcon(
            icon: Icons.edit_outlined,
            tooltip: "Edit",
            onPressed: _edit,
          ),
        if (_can.canRegenerate)
          ActionIcon(
            icon: Icons.refresh,
            tooltip: "Regenerate",
            onPressed: _can.regenerate,
          ),
      ],
    ),
    // Kept whether or not there is anything to show, so a message does not
    // shift under the pointer the moment the actions appear.
    // The reactions stay put whether the actions show or not: they are what
    // was said about the message, not something to do to it. They lead the
    // row from its outer end — the left under a reply, the right under the
    // user's own, the row read backwards there — so the actions fading beside
    // them never move them. The divider goes with the actions, so it never
    // stands alone.
    builder: (context, shown, child) {
      final up = shown || widget.isSpeaking;
      final reactions = widget.reactions;
      // Only this row's order: the icons inside keep the page's direction.
      final from = widget.message.role == MessageRole.user
          ? TextDirection.rtl
          : TextDirection.ltr;
      return SizedBox(
        height: ActionIcon.height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: from,
          children: [
            for (final emoji in reactions)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(emoji, style: const TextStyle(fontSize: 16)),
              ),
            AnimatedOpacity(
              opacity: up ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: IgnorePointer(
                ignoring: !up,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  textDirection: from,
                  children: [
                    if (reactions.isNotEmpty)
                      const VerticalDivider(width: 13, indent: 6, endIndent: 6),
                    child!,
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  MessageActions get _can =>
      widget.actions ?? MessageActions.none(widget.message);

  /// An arrow to the thread [step] along, dead at either end and during a
  /// turn.
  Widget _step(IconData icon, String tooltip, int step) => ActionIcon(
    icon: icon,
    tooltip: tooltip,
    onPressed: _can.canStep(step) ? () => _can.step(step) : null,
  );

  /// The message as the core lays it out, each block drawn its own way.
  List<Widget> _rows(BuildContext context, Color? bg) {
    final theme = Theme.of(context);
    final blocks = _layout.blocks(
      WidgetReader(ref),
      MessageMoment(
        waiting: widget.isWaiting,
        status: widget.waitingStatus,
        notice: widget.waitingNotice,
        shellOutput: widget.shellOutput,
        canRetry: _can.canRegenerate,
      ),
    );
    return [
      for (final block in blocks)
        switch (block) {
          BubbleBlock() => _bubble(context, bg, block),
          ActivityBlock(:final node) => _label(ActivityNodeView(node)),
          ActivityRunBlock(:final start, :final nodes) => ActivityGroup(
            key: ValueKey(start),
            children: [
              for (final node in nodes) _label(ActivityNodeView(node)),
            ],
          ),
          FileBlock(:final file) => AttachmentStrip(
            children: [
              AttachmentChip.sent(file, chatId: widget.chatId, size: 256),
            ],
          ),
          ShellRunBlock(:final run) => ShellRunBubble(run: run),
          SteerBlock() => Align(
            key: widget.steerKey?.call(block.message.id),
            alignment: Alignment.centerRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4, bottom: 2),
                  child: Text(
                    block.heading,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _bubble(
                  context,
                  _fillOf(theme, block.bubble.tint),
                  block.bubble,
                ),
              ],
            ),
          ),
        },
    ];
  }

  /// A label sits inside the message's selection region but is not part of
  /// what the message says, so dragging past one must not put "Thought for
  /// 12 seconds" on the clipboard. Its own detail is a route and so is
  /// outside the region already.
  Widget _label(Widget child) => SelectionContainer.disabled(child: child);

  Widget _said(Said said) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: switch (said) {
      ProseSaid(:final markdown, :final caret) => MessageText(
        text: markdown,
        isError: false,
        isWaiting: widget.isWaiting,
        caret: caret,
        onTapLink: widget.onTapLink,
      ),
      ErrorSaid() => MessageText(
        text: said.text,
        isError: true,
        isWaiting: widget.isWaiting,
        caret: false,
        onTapLink: widget.onTapLink,
      ),
      CommandSaid(:final command) => ShellCommandText(command: command),
    },
  );

  Widget _trailing(BuildContext context, Trailing trailing) {
    final theme = Theme.of(context);
    return switch (trailing) {
      WaitingTrailing() => _Spinner(
        color: theme.colorScheme.onSurfaceVariant,
        line: trailing.line,
        isError: trailing.notice != null,
      ),
      LiveOutputTrailing(:final output) => LiveShellOutput(code: output),
      RetryTrailing() => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _can.canRegenerate ? _can.regenerate : null,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text("Retry"),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ),
    };
  }

  Widget _bubble(BuildContext context, Color? bg, BubbleBlock block) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (block.files.isNotEmpty)
          AttachmentStrip(
            children: [
              for (final f in block.files)
                AttachmentChip.sent(f, chatId: widget.chatId),
            ],
          ),
        if (bg == null)
          ...block.said.map(_said)
        else
          Theme(
            data: onFillTheme(Theme.of(context), bg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [...block.said.map(_said)],
            ),
          ),
        for (final t in block.trailing) _trailing(context, t),
      ],
    );
    if (bg == null) return SizedBox(width: double.infinity, child: content);
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: content,
      ),
    );
  }
}

/// Stands in for the reply until the first text arrives, beside the line
/// the core picked for it — trouble, in the error colour, over what the turn
/// is doing.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.color, this.line, this.isError = false});
  final Color color;
  final String? line;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = line;
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
                  color: isError ? theme.colorScheme.error : color,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The colour a tint fills with here: none for a reply, which is the page.
Color? _fillOf(ThemeData theme, BubbleTint tint) => switch (tint) {
  BubbleTint.none => null,
  BubbleTint.prompt => theme.colorScheme.primaryContainer,
  BubbleTint.command => theme.colorScheme.surfaceContainerHighest,
  BubbleTint.notice ||
  BubbleTint.tool ||
  BubbleTint.system => theme.colorScheme.tertiaryContainer,
};
