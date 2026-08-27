import "package:flutter/material.dart";

import "add_button_row.dart";
import "dialogs.dart";
import "editable_row.dart";
import "section_header.dart";

/// The editable list of command environment variables, over whatever level
/// holds them — the app's, and a project's beside it. The values are mostly
/// API keys, so they are drawn masked, and the edit and remove are the pair
/// dialog and the row's cross.
class EnvironmentSection extends StatefulWidget {
  const EnvironmentSection({
    super.key,
    required this.env,
    required this.description,
    required this.onSaved,
  });

  /// The variables as they stand.
  final Map<String, String> env;

  /// The section's own line: what the variables are for at this level.
  final String description;

  /// What the whole map is saved as. A rename is a new map with the old name
  /// out of it.
  final Future<void> Function(Map<String, String>) onSaved;

  @override
  State<EnvironmentSection> createState() => _EnvironmentSectionState();
}

class _EnvironmentSectionState extends State<EnvironmentSection> {
  Future<void> _edit({String? name}) async {
    final env = widget.env;
    final pair = await promptForPair(
      context,
      title: name == null ? "Add variable" : "Edit $name",
      nameLabel: "Name",
      valueLabel: "Value",
      name: name ?? "",
      value: name == null ? "" : env[name] ?? "",
    );
    if (pair == null || !mounted) return;
    // A rename drops the old key rather than leaving both behind.
    final next = {...env}..remove(name);
    next[pair.name] = pair.value;
    await widget.onSaved(next);
  }

  Future<void> _remove(String name) async {
    final next = {...widget.env}..remove(name);
    await widget.onSaved(next);
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.env.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Environment", description: widget.description),
        for (final name in names)
          EditableRow(
            title: name,
            // These are mostly API keys, and settings is a page people show
            // people.
            subtitle: "•" * widget.env[name]!.length.clamp(0, 24),
            removeLabel: "Remove $name",
            onTap: () => _edit(name: name),
            onRemove: () => _remove(name),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add variable"),
            onPressed: () => _edit(),
          ),
        ),
      ],
    );
  }
}
