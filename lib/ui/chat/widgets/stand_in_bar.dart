import "package:flutter/material.dart";

/// What sits where the composer does when there is nothing to type into:
/// why, and what can be done about it. With one action or none it is one
/// centred line; with more, the [text] wraps and the [actions] go under it.
/// [alarming] draws it in the error colour.
class StandInBar extends StatelessWidget {
  const StandInBar({
    super.key,
    required this.icon,
    required this.text,
    this.actions = const [],
    this.alarming = false,
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;
  final bool alarming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = alarming
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final style = TextStyle(color: color, fontSize: 13);
    final mark = Icon(icon, size: 16, color: color);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: actions.length <= 1
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  mark,
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      style: style,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final action in actions) ...[
                    const SizedBox(width: 12),
                    action,
                  ],
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      mark,
                      const SizedBox(width: 8),
                      Expanded(child: Text(text, style: style)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 4,
                    children: actions,
                  ),
                ],
              ),
      ),
    );
  }
}
