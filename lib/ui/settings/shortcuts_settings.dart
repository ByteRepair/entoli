import "package:flutter/material.dart";

import "../shortcuts.dart";
import "../widgets/section_header.dart";

/// The keyboard shortcuts, on every platform: a phone or tablet can have a
/// keyboard attached, and then they work there too.
class ShortcutsSection extends StatelessWidget {
  const ShortcutsSection({super.key});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader("Keyboard shortcuts"),
          for (final shortcut in AppShortcut.values)
            ListTile(
              title: Text(shortcut.label),
              trailing: _Keys(shortcut.keyCaps),
            ),
        ],
      );
}

class _Keys extends StatelessWidget {
  const _Keys(this.caps);

  final List<String> caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final cap in caps)
          Container(
            constraints: const BoxConstraints(minWidth: 28),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              cap,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}
