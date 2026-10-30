import "package:flutter/material.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../../domain/models.dart";
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../widgets/scrolling.dart" show ScrollFollow;
import "../widgets/code_block.dart" show codeBlockDecoration, codeBlockStyle;
import "../widgets/message_text.dart" show StreamingCaret;
import "../widgets/shell_run.dart" show ShellCommandText;

typedef ActivitySection = ({String? label, String? body, bool isError});

/// A message as it stands now, for a drawer left open while its turn runs.
/// [running] is the room's: a block or a call with no end yet is live only
/// while a turn is.
typedef LiveMessage = ({Message? message, String? shellOutput, bool running});

/// Message [id] of [view] as a drawer follows it.
LiveMessage liveMessageOf(ChatViewState view, String id) => (
  message: view.chat?.messages.where((m) => m.id == id).firstOrNull,
  shellOutput: view.shellOutput[id],
  running: view.isRunning,
);

/// Where a label's drawer reads its message from once it is open. The label
/// cannot be: it is rebuilt per delta, folded into a collapsed run when its
/// block closes, and gone when the list scrolls it away, all while the drawer
/// it opened is still up. Above each message on the chat page; absent, a
/// drawer shows what it was opened with and nothing more.
class ActivitySource extends InheritedWidget {
  const ActivitySource({super.key, required this.live, required super.child});

  final ProviderListenable<LiveMessage> live;

  static ProviderListenable<LiveMessage>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ActivitySource>()?.live;

  // Read once, at the tap that opens a drawer, so nothing depends on it.
  @override
  bool updateShouldNotify(ActivitySource oldWidget) => false;
}

/// The drawer behind a label, opened at most of the screen. A modal route, so
/// the back key closes it; on a wide window as wide as a reading column, not
/// Material's 640. On the surface a dialog sits on, which is what it is drawn
/// after.
Future<T?> showActivityCard<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      constraints: const BoxConstraints(maxWidth: 960),
      builder: builder,
    );

/// A status line under a card's title: "Running · pid 4001", "Exit code 1".
typedef ActivityStatus = ({String text, bool isError});

/// What a drawer draws, whoever is feeding it. Sections with nothing in them
/// are left out, so a tool that returned nothing does not show an empty
/// heading. [command] is set the way a `!` message is, under the title.
///
/// It opens at most of the screen and grows to the whole of it: a drawer
/// sized to a one-line output was a strip at the bottom of the window, and a
/// fraction of the height left empty below a long one is a fraction of the
/// output not read. While [live] it keeps to the end of what is arriving
/// until the reader scrolls back.
class ActivityCard extends StatefulWidget {
  const ActivityCard({
    super.key,
    required this.title,
    required this.sections,
    this.icon,
    this.command,
    this.status,
    this.actions = const [],
    this.mono = false,
    this.live = false,
    this.below,
  });

  final String title;
  final IconData? icon;
  final String? command;
  final ActivityStatus? status;

  /// Beside the close button: what can be done to the thing shown.
  final List<Widget> actions;

  final List<ActivitySection> sections;
  final bool mono;
  final bool live;
  final Widget? below;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  final _scroll = ScrollController();
  late final _follow = ScrollFollow(_scroll);

  /// How much of the screen the drawer takes before what is in it asks for
  /// more.
  static const _openAt = 0.6;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extra = widget.below;
    final live = widget.live;
    final filled = widget.sections
        .where((s) => s.body != null && s.body!.trim().isNotEmpty)
        .toList();
    if (live) _follow.jumpIfFollowing();

    final muted = theme.colorScheme.onSurfaceVariant;
    final status = widget.status;
    final header = Row(
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 22, color: muted),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            widget.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (live)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: muted),
            ),
          ),
        ...widget.actions,
        IconButton(
          tooltip: "Close",
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    Widget body(ActivitySection section, {required bool last}) {
      final style = widget.mono
          ? codeBlockStyle(
              theme,
            ).copyWith(color: section.isError ? theme.colorScheme.error : null)
          : theme.textTheme.bodyMedium?.copyWith(
              color: section.isError ? theme.colorScheme.error : null,
              height: 1.5,
            );
      final caret = live && last && !section.isError;
      final text = caret
          ? Text.rich(
              TextSpan(
                text: section.body,
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: StreamingCaret(
                      color: theme.colorScheme.primary,
                      height: style?.fontSize ?? 14,
                    ),
                  ),
                ],
              ),
              style: style,
            )
          // The newline output ends on would draw as a blank line under it.
          : Text(
              widget.mono ? section.body!.trimRight() : section.body!,
              style: style,
            );
      if (!widget.mono) return text;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: codeBlockDecoration(theme),
        child: text,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight * _openAt),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (status != null)
                Text(
                  status.text,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: status.isError ? theme.colorScheme.error : muted,
                  ),
                ),
              const SizedBox(height: 8),
              Flexible(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _follow.onNotification,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.command case final command?)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    bottom: 4,
                                  ),
                                  child: ShellCommandText(command: command),
                                ),
                              for (final (i, section) in filled.indexed) ...[
                                if (section.label != null)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 16,
                                      bottom: 8,
                                    ),
                                    child: SelectionContainer.disabled(
                                      child: Text(
                                        section.label!,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: muted,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ),
                                body(
                                  section,
                                  last: extra == null && i == filled.length - 1,
                                ),
                              ],
                            ],
                          ),
                        ),
                        ?extra,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
