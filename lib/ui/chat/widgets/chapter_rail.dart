import "dart:math" as math;

import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter/gestures.dart" show kPrimaryButton;
import "package:flutter/material.dart";

import "../../../domain/models.dart";

/// One thing the user said, as a place in the conversation to go back to.
typedef Chapter = ({
  /// The message id of what was said, which is what the page scrolls to: a
  /// prompt's, or a steer's inside the reply it was read into.
  String id,

  /// The message whose row it is in: the prompt itself, or the reply a steer
  /// was read into.
  String row,

  /// Its first line, for the rail's tooltip, cut to [_previewLength].
  String preview,

  /// How many threads were written somewhere in this turn — at the prompt (an
  /// edit) or at a reply under it (a regenerate). One where nothing branched,
  /// and on a steer, which is not where a turn starts.
  int threads,
});

/// The chapters of the thread being read: every prompt, and every steer said
/// over a turn, oldest first. A turn is the prompt and what answered it, up
/// to the next prompt, so a branch at any message in it marks the prompt's
/// chapter.
List<Chapter> chaptersOf(Chat chat) {
  final chapters = <Chapter>[];
  int? prompt;
  for (final message in chat.messages) {
    final threads = chat.threadsAt(message.id).length;
    if (message.role == MessageRole.user) {
      prompt = chapters.length;
      chapters.add((
        id: message.id,
        row: message.id,
        preview: _firstLine(message.plainText),
        threads: threads,
      ));
      continue;
    }
    final at = prompt;
    if (at != null && threads > chapters[at].threads) {
      final p = chapters[at];
      chapters[at] = (id: p.id, row: p.row, preview: p.preview, threads: threads);
    }
    for (final part in message.parts) {
      if (part case SteerPart(message: final said)) {
        chapters.add((
          id: said.id,
          row: message.id,
          preview: _firstLine(said.plainText),
          threads: 1,
        ));
      }
    }
  }
  return chapters;
}

/// How much of a prompt the tooltip shows.
const _previewLength = 50;

String _firstLine(String text) {
  final trimmed = text.trim();
  final end = trimmed.indexOf("\n");
  final line = (end < 0 ? trimmed : trimmed.substring(0, end)).trim();
  if (line.isEmpty) return "(attachment)";
  if (line.length <= _previewLength) return line;
  return "${line.substring(0, _previewLength).trimRight()}...";
}

/// The conversation's table of contents: a tick per prompt beside the column,
/// the one being read picked out, a fork where the turn has other threads.
/// It only exists where the margin beside the column has room for it, so it
/// never moves the conversation over.
///
/// A press selects, not a tap, and so does every move while pressed: dragging
/// a mouse or a finger along the rail scrubs the conversation from prompt to
/// prompt. One [Listener] over the whole rail rather than one per tick,
/// because a pointer stays with the widget it went down on, and a tick's own
/// handler would never hear the drag reach the next one. The rail does not
/// scroll — a drag on it is a scrub — so ticks close up to fit when there are
/// more than its height holds at their usual pitch.
class ChapterRail extends StatefulWidget {
  const ChapterRail({
    super.key,
    required this.chapters,
    required this.current,
    required this.onSelect,
  });

  /// The width it needs beside the column.
  static const double width = 56;

  final List<Chapter> chapters;

  /// Which chapter is in view. A notifier so the scroll redraws the rail and
  /// nothing else.
  final ValueListenable<int?> current;

  /// Go to chapter [index]. [scrubbing] is a move during a press rather than
  /// the press itself, which wants to land at once rather than animate.
  final void Function(int index, {required bool scrubbing}) onSelect;

  @override
  State<ChapterRail> createState() => _ChapterRailState();
}

class _ChapterRailState extends State<ChapterRail> {
  static const _pitch = 18.0;
  static const _minPitch = 4.0;
  static const _pad = 16.0;

  /// The tick the press is on, so a move within it selects nothing again.
  int? _pressed;

  int _at(double y, double pitch) =>
      (y / pitch).floor().clamp(0, widget.chapters.length - 1);

  void _press(PointerEvent event, double pitch, {required bool scrubbing}) {
    if (event.buttons & kPrimaryButton == 0) return;
    final i = _at(event.localPosition.dy, pitch);
    if (scrubbing && i == _pressed) return;
    _pressed = i;
    widget.onSelect(i, scrubbing: scrubbing);
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters;
    if (chapters.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: ChapterRail.width,
      child: LayoutBuilder(builder: (context, constraints) {
        final room = constraints.maxHeight - _pad * 2;
        final pitch = (room / chapters.length).clamp(_minPitch, _pitch);
        return Center(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _press(e, pitch, scrubbing: false),
            onPointerMove: (e) => _press(e, pitch, scrubbing: true),
            onPointerUp: (_) => _pressed = null,
            onPointerCancel: (_) => _pressed = null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, chapter) in chapters.indexed)
                  _Tick(
                      chapter: chapter,
                      index: i,
                      current: widget.current,
                      height: pitch),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _Tick extends StatefulWidget {
  const _Tick({
    required this.chapter,
    required this.index,
    required this.current,
    required this.height,
  });

  final Chapter chapter;
  final int index;

  /// Listened to by each tick, so a chapter change rebuilds the two whose
  /// selection flips rather than the whole rail, mid-scroll.
  final ValueListenable<int?> current;

  /// The rail's pitch: every tick is the same height, which is what lets the
  /// rail find the one under a pointer by arithmetic.
  final double height;

  @override
  State<_Tick> createState() => _TickState();
}

class _TickState extends State<_Tick> {
  bool _hovered = false;
  late bool _selected = _isSelected;

  bool get _isSelected => widget.current.value == widget.index;

  @override
  void initState() {
    super.initState();
    widget.current.addListener(_select);
  }

  @override
  void didUpdateWidget(_Tick old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      old.current.removeListener(_select);
      widget.current.addListener(_select);
    }
    _selected = _isSelected;
  }

  @override
  void dispose() {
    widget.current.removeListener(_select);
    super.dispose();
  }

  void _select() {
    if (_isSelected != _selected) setState(() => _selected = _isSelected);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chapter = widget.chapter;
    final branched = chapter.threads > 1;
    final lit = _selected || _hovered;
    final colour = _selected
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: _hovered ? 0.9 : 0.45);
    return Tooltip(
      message: branched
          ? "${chapter.preview}\n${chapter.threads} threads branch here"
          : chapter.preview,
      waitDuration: const Duration(milliseconds: 300),
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: SizedBox(
          height: widget.height,
          child: Row(
            children: [
              // The fork sits left of the tick, towards the conversation,
              // so the ticks themselves stay in one straight line.
              SizedBox(
                width: 20,
                child: branched
                    ? Icon(Icons.call_split,
                        key: const ValueKey("branched"),
                        size: math.min(13, widget.height),
                        color: colour)
                    : null,
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: lit ? 22 : 14,
                height: _selected ? 3 : 2,
                decoration: BoxDecoration(
                  color: colour,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
