import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../fonts.dart";

/// One thing the chat has running, as a pill in the row above the composer:
/// a spinner, or [icon] where there is one, and what it is.
class RunningPill extends StatelessWidget {
  const RunningPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.mono = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.onPrimaryContainer;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: ActionChip(
        avatar: icon == null
            ? runningSpinner(colour)
            : Icon(icon, size: 16, color: colour),
        label: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? TextStyle(fontFamily: monoFamily, fontSize: 12, color: colour)
              : theme.textTheme.labelMedium
                  ?.copyWith(color: colour, fontWeight: FontWeight.w500),
        ),
        backgroundColor: theme.colorScheme.primaryContainer,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: onPressed,
      ),
    );
  }
}

/// The small spinner of a pill or a group of them.
Widget runningSpinner(Color colour) => SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(strokeWidth: 1.5, color: colour),
    );

/// One thing a chat has running beside the reply, as the row above the
/// composer draws it.
class RunningThing {
  const RunningThing({
    required this.label,
    required this.tooltip,
    required this.open,
    this.group,
    this.icon,
    this.mono = false,
  });

  /// What it is gathered under with the rest of its kind, as a singular noun
  /// ("background task"); null for one that stands alone, ahead of the
  /// groups.
  final String? group;
  final String label;
  final String tooltip;

  /// Shown in place of the spinner.
  final IconData? icon;
  final bool mono;

  /// Opens what it is, from the pill's [BuildContext].
  final void Function(BuildContext context) open;
}

/// A kind of thing a chat can have running. The row asks each source for
/// what it has, in the order the sources are listed, and knows nothing of
/// what they are.
abstract class RunningSource {
  const RunningSource();

  /// What [chatId] has running now, watching through [ref] whatever it reads
  /// beyond [view].
  List<RunningThing> things(WidgetRef ref, ChatViewState view, String chatId);
}
