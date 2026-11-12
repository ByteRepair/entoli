import "package:flutter/material.dart";

import "../../../app/transcript/activities/todo.dart" show TodoWords;
import "../../../domain/todo.dart";
import "plan_view.dart" show taskLook;

/// The latest turn's task list, one row above the composer while it has one:
/// how far it is and the task under way, opening to every task. See "The
/// task list, on screen" in `lib/ui/chat/AGENTS.md`.
class TodoStrip extends StatefulWidget {
  const TodoStrip({super.key, required this.list});

  /// The list as the latest turn left it; null or empty draws nothing.
  final TodoList? list;

  @override
  State<TodoStrip> createState() => _TodoStripState();
}

class _TodoStripState extends State<TodoStrip> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    if (list == null || list.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = list.items.length;
    final finished = list.allDone;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    finished ? Icons.check_circle_outline : Icons.checklist,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "${list.done}/$total  ",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      list.headline,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                    semanticLabel: _open ? "Hide the tasks" : "Show the tasks",
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _TodoChecklist(list: list),
            ),
        ],
      ),
    );
  }
}

/// Every task of [list], each with where it stands: the strip's open half.
class _TodoChecklist extends StatelessWidget {
  const _TodoChecklist({required this.list});

  final TodoList list;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final item in list.items) _row(item, theme)],
    );
  }

  Widget _row(TodoItem item, ThemeData theme) {
    final scheme = theme.colorScheme;
    final (icon, colour, status) = taskLook(item.status.asPlan, scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colour, semanticLabel: status),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.content,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: item.finished ? scheme.onSurfaceVariant : null,
                fontWeight: item.status == TodoStatus.inProgress
                    ? FontWeight.w600
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
