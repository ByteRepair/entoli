import "package:flutter/material.dart";

import "../fonts.dart";
import "dialogs.dart" show copyToClipboard;

/// A settings card: the icon at the top left, the title beside it, the
/// subtitle under, and, where it tappable, the right-angle arrow at the
/// top right saying so. A row of them is [SettingsCardRow].
///
/// What a tap does is the caller's — [SettingsCard.copy] copies its value,
/// a navigation card pushes its page. Null [onTap] is a card that states a
/// fact and takes no gesture: no InkWell, no arrow.
///
/// Where an action beside the tap is wanted, [trailing] takes it — the
/// description card's reset button rides there, the tap staying the dialog.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
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
        onTap = null,
        trailing = null,
        _copySaid = said;

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? _copySaid;

  /// What the card's subtitle reads as, where the copy card holds a verbatim
  /// value instead of a fact about the thing.
  static const _mono = TextStyle(fontFamily: monoFamily);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = _copySaid;
    final action = onTap ??
        (copy == null
            ? null
            : () => copyToClipboard(context, subtitle, said: copy));
    final ending = trailing ??
        (action == null
            ? null
            : copy == null
                ? const Icon(Icons.arrow_right)
                : const Icon(Icons.copy));
    final style = copy == null
        ? theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
        : _mono;
    // Clipped, so the ink takes the card's own shape at every corner radius.
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action,
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
                style: style,
                maxLines: 2,
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
  const SettingsCardRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // The constraints are already inside the padding.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        const gap = 8.0;
        final width = ((constraints.maxWidth - gap) / 2).clamp(160.0, 240.0);
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: width, child: child),
          ],
        );
      }),
    );
  }
}