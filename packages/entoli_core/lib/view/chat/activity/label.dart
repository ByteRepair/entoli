import "package:flutter/material.dart";

/// The icon of a label whose run is still going.
Widget labelSpinner(BuildContext context) => Padding(
  padding: const EdgeInsets.all(1),
  child: CircularProgressIndicator(
    strokeWidth: 2,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  ),
);

/// The one line every activity above a reply is drawn as, frameless so it
/// reads as a label until it is tapped.
class ActivityLabel extends StatelessWidget {
  const ActivityLabel({
    super.key,
    required this.icon,
    required this.text,
    required this.onTap,
    this.isError = false,
    this.iconWidget,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final bool isError;

  /// Overrides [icon] where the caller has a widget rather than an icon — a
  /// running tool's spinner, for instance.
  final Widget? iconWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        style: labelStyle(color, labelText(theme)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: labelIcon,
              child: iconWidget ?? Icon(icon, size: labelIcon),
            ),
            const SizedBox(width: labelGap),
            // One line: the label names what happened, the drawer says it.
            Flexible(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: color.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

/// The labels' type: the body size rather than Material's 12pt label tier,
/// which read as squeezed against a reply in Source Serif, but no weight and
/// the muted colour, so a label stays quieter than anything said.
TextStyle? labelText(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5, height: 1.3);

const double labelIcon = 16;
const double labelGap = 10;
const double labelPadX = 10;

/// The frameless, one-line button every label above a reply is drawn as.
ButtonStyle labelStyle(Color color, TextStyle? text) => TextButton.styleFrom(
  foregroundColor: color,
  textStyle: text,
  padding: const EdgeInsets.symmetric(horizontal: labelPadX, vertical: 7),
  minimumSize: const Size(0, 34),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
);

/// A run of consecutive activities none of which is important (see
/// `Activity.important`), gathered by `MessageBubble._rows` and shown behind a single
/// centered toggle. Two or more such labels in a row are worth hiding behind it;
/// one on its own is not, and `_rows` leaves a lone label where it is.
///
/// State is per-run and in-memory: a run is [ValueKey]ed on its first part's
/// index so a per-delta rebuild of the message keeps the same [_collapsed]
/// across the rebuilds the streamer triggers, but a reload or a thread switch
/// starts collapsed again, the way every fresh view does.
class ActivityGroup extends StatefulWidget {
  const ActivityGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  State<ActivityGroup> createState() => _ActivityGroupState();
}

class _ActivityGroupState extends State<ActivityGroup> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              onPressed: () => setState(() => _collapsed = !_collapsed),
              icon: Icon(
                _collapsed ? Icons.expand_more : Icons.expand_less,
                size: 16,
              ),
              label: Text(
                _collapsed ? "Expand activities" : "Collapse activities",
              ),
              style: labelStyle(
                theme.colorScheme.onSurfaceVariant,
                labelText(theme),
              ),
            ),
          ),
          if (!_collapsed) ...widget.children,
        ],
      ),
    );
  }
}
