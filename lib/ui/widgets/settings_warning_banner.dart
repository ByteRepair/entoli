import "package:flutter/material.dart";

/// A one-line warning strip under a settings section header: an icon beside a
/// line of `bodySmall` text, both in the given colour. Shared out of the
/// Terminal and Byte Repair categories, which had spelled the same layout out
/// twice — and a tweak to the padding or typography had to land in both.
class SettingsWarningBanner extends StatelessWidget {
  const SettingsWarningBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}