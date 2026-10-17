import "package:flutter/material.dart";

import "../../settings/settings_page.dart";

/// What sits where the composer does on a project that requires setup and
/// has not been set up yet: why there is nothing to type into, and the way
/// to change that. Follows `ViewOnlyBar`'s shape.
class NeedsSetupBar extends StatelessWidget {
  const NeedsSetupBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.build_outlined, size: 16, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                "Setup required before this project can be used.",
                style: TextStyle(color: color, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: () => _openSetupSettings(context),
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text("Open Settings"),
            ),
          ],
        ),
      ),
    );
  }
}

/// The settings page at the Byte Repair category, where setup is run.
Future<void> _openSetupSettings(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SettingsPage(
          initialCategory: SettingsCategory.byteRepair,
          focus: true,
        ),
      ),
    );