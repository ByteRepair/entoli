import "package:flutter/material.dart";

import "../fonts.dart";
import "dialogs.dart" show copyToClipboard;

/// A settings card: the icon at the top left, the title beside it, the
/// subtitle under, and, where it is tappable, the right-angle arrow at the
/// top right saying so. A row of them is [SettingsCardRow].
///
/// What a tap does is the caller's — [SettingsCard.copy] copies its value,
/// a navigation card pushes its page. Null [onTap] is a card that states a
/// fact and takes no gesture: no InkWell, no arrow.
///
/// Where an action beside the tap is wanted, [trailing] takes it — the
/// description card's [ResetButton] rides there, the tap staying the dialog.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.subtitleStyle,
    this.subtitleMaxLines = 2,
    this.onTap,
    this.trailing,
    this.trailingIcon,
  }) : _copySaid = null;

  /// The card whose whole action is to copy [value], said in a snack bar.
  /// The value is the subtitle, in the mono face the other verbatim values
  /// are held in, and the ending element is the copy glyph rather than the
  /// arrow — the arrow says "opens something", this says what the tap takes.
  const SettingsCard.copy({
    super.key,
    required this.icon,
    required this.title,
    required String value,
    required String said,
  })  : subtitle = value,
        subtitleStyle = const TextStyle(fontFamily: monoFamily),
        subtitleMaxLines = 2,
        onTap = null,
        trailing = null,
        trailingIcon = Icons.copy,
        _copySaid = said;

  final IconData icon;
  final String title;
  final String subtitle;
  final TextStyle? subtitleStyle;
  final int subtitleMaxLines;
  final VoidCallback? onTap;
  final Widget? trailing;
  final IconData? trailingIcon;
  final String? _copySaid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = _copySaid;
    final action = onTap ??
        (copy == null
            ? null
            : () => copyToClipboard(context, subtitle, said: copy));
    final ending = trailing ??
        (action == null ? null : Icon(trailingIcon ?? Icons.arrow_right));
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: action,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon,
                      size: 20, color: theme.colorScheme.onSurfaceVariant),
                  const Spacer(),
                  ?ending,
                ],
              ),
              const SizedBox(height: 8),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: subtitleStyle ??
                    theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: subtitleMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A wrapping row of fixed-width cards: two per phone line, three where the
/// window is wide enough to fit the cap. Not flex — a row of equal cards
/// reads as a grid, while flexing would give the pairs beside a wide one
/// different widths line to line.
class SettingsCardRow extends StatelessWidget {
  const SettingsCardRow({super.key, required this.children, this.cap = 240});

  final List<Widget> children;

  /// The widest a card becomes, so three on a wide window are still cards
  /// rather than three slabs stretched across it.
  final double cap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 8.0;
      final width = ((constraints.maxWidth - gap) / 2).clamp(160.0, cap);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: width, child: child),
          ],
        ),
      );
    });
  }
}