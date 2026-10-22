import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter/material.dart";

import "../../../domain/models.dart";

/// One thing the user said, as a place in the conversation to go back to.
typedef Chapter = ({
  /// The prompt's message id, which is what the page scrolls to.
  String id,

  /// Its first line, for the rail's tooltip.
  String preview,

  /// How many threads were written somewhere in this turn — at the prompt (an
  /// edit) or at a reply under it (a regenerate). One where nothing branched.
  int threads,
});

/// The chapters of the thread being read: every prompt, oldest first. A turn
/// is the prompt and what answered it, up to the next prompt, so a branch at
/// any message in it marks the prompt's chapter.
List<Chapter> chaptersOf(Chat chat) {
  final chapters = <Chapter>[];
  for (final message in chat.messages) {
    final threads = chat.threadsAt(message.id).length;
    if (message.role == MessageRole.user) {
      chapters.add((id: message.id, preview: _firstLine(message.plainText), threads: threads));
    } else if (chapters.isNotEmpty && threads > chapters.last.threads) {
      final last = chapters.removeLast();
      chapters.add((id: last.id, preview: last.preview, threads: threads));
    }
  }
  return chapters;
}

String _firstLine(String text) {
  final line = text.trim().split("\n").first.trim();
  return line.isEmpty ? "(attachment)" : line;
}

/// The conversation's table of contents: a tick per prompt beside the column,
/// the one being read picked out, a fork where the turn has other threads.
/// Tapping a tick goes there. It only exists where the margin beside the
/// column has room for it, so it never moves the conversation over.
class ChapterRail extends StatelessWidget {
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

  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (chapters.length < 2) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: ValueListenableBuilder<int?>(
            valueListenable: current,
            builder: (context, at, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, chapter) in chapters.indexed)
                  _Tick(
                    chapter: chapter,
                    selected: i == at,
                    onTap: () => onSelect(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tick extends StatefulWidget {
  const _Tick({required this.chapter, required this.selected, required this.onTap});

  final Chapter chapter;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Tick> createState() => _TickState();
}

class _TickState extends State<_Tick> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chapter = widget.chapter;
    final branched = chapter.threads > 1;
    final lit = widget.selected || _hovered;
    final colour = widget.selected
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
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 18,
            child: Row(
              children: [
                // The fork sits left of the tick, towards the conversation,
                // so the ticks themselves stay in one straight line.
                SizedBox(
                  width: 20,
                  child: branched
                      ? Icon(Icons.call_split,
                          key: const ValueKey("branched"), size: 13, color: colour)
                      : null,
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: lit ? 22 : 14,
                  height: widget.selected ? 3 : 2,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
