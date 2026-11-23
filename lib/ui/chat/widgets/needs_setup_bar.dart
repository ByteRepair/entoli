import "package:flutter/material.dart";

import "../../settings/settings_category.dart";
import "stand_in_bar.dart";

/// What sits where the composer does on a project that requires setup and
/// has not been set up yet: why there is nothing to type into, and the way
/// to change that.
class NeedsSetupBar extends StatelessWidget {
  const NeedsSetupBar({super.key});

  @override
  Widget build(BuildContext context) => StandInBar(
    icon: Icons.build_outlined,
    text: "Setup required before this project can be used.",
    actions: [
      TextButton.icon(
        onPressed: () => _openSetupSettings(context),
        icon: const Icon(Icons.settings_outlined, size: 16),
        label: const Text("Open Settings"),
      ),
    ],
  );
}

/// The settings page at the Byte Repair category, where setup is run.
Future<void> _openSetupSettings(BuildContext context) =>
    openSettings(context, category: SettingsCategory.byteRepair, focus: true);
