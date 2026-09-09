import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/project.dart" show projectLabel;
import "../../providers.dart";

/// Where a skill being installed goes: the default project's directory, or a
/// named user project's. Null is the default project — "Global" — the way a
/// project is named everywhere a project is named. Shared by the Skills
/// settings page's import flow and the skill-install preview page, so the two
/// install routes offer the same list: the user's projects alone, a built-in's
/// directory not being the user's to write into.
class InstallDestination extends ConsumerWidget {
  const InstallDestination({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectListProvider).value ?? const <String>[];
    return DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: const InputDecoration(labelText: "Install to"),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text("Global")),
        for (final project in projects)
          DropdownMenuItem<String?>(value: project, child: Text(projectLabel(project))),
      ],
      onChanged: onChanged,
    );
  }
}