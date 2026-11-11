import "package:flutter/material.dart";

import "add_button_row.dart";
import "dialogs.dart";
import "editable_row.dart";
import "section_header.dart";

/// The editable list of command environment variables, over whatever level
/// holds them — the app's, and a project's beside it. The values are mostly
/// API keys, so they are drawn masked, and the edit and remove are the pair
/// dialog and the row's cross.
class EnvironmentSection extends StatelessWidget {
  const EnvironmentSection({
    super.key,
    required this.env,
    required this.description,
    required this.onSaved,
  });

  final Map<String, String> env;
  final String description;
  final Future<void> Function(Map<String, String>) onSaved;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader("Environment", description: description),
      EnvironmentRows(env: env, onSaved: onSaved),
    ],
  );
}

/// The variables under a header someone else draws: one row each, opened to
/// edit, and a button to add one.
class EnvironmentRows extends StatefulWidget {
  const EnvironmentRows({super.key, required this.env, required this.onSaved});

  /// The variables as they stand.
  final Map<String, String> env;

  /// What the whole map is saved as. A rename is a new map with the old name
  /// out of it.
  final Future<void> Function(Map<String, String>) onSaved;

  @override
  State<EnvironmentRows> createState() => _EnvironmentRowsState();
}

class _EnvironmentRowsState extends State<EnvironmentRows> {
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
