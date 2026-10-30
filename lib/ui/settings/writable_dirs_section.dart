import "package:flutter/material.dart";

import "../widgets/add_button_row.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";

/// The machine directories one tier's sandboxed commands may write to, beside
/// the workspace. The project settings page serves it; the app-level list
/// does not exist, the workspace being where the machine grants already.
class WritableDirsSection extends StatefulWidget {
  const WritableDirsSection({
    super.key,
    required this.dirs,
    required this.description,
    required this.onSaved,
  });

  final List<String> dirs;
  final String description;
  final Future<void> Function(List<String>) onSaved;

  @override
  State<WritableDirsSection> createState() => _WritableDirsSectionState();
}

class _WritableDirsSectionState extends State<WritableDirsSection> {
  Future<void> _edit({String? existing}) async {
    final dir = await promptForText(
      context,
      title: existing == null ? "Add directory" : "Edit directory",
      initial: existing ?? "",
      confirmLabel: "Save",
    );
    if (dir == null || !mounted) return;
    final next = [...widget.dirs]..remove(existing);
    next.add(dir);
    await widget.onSaved(next);
  }

  Future<void> _remove(String dir) async {
    await widget.onSaved([...widget.dirs]..remove(dir));
  }

  @override
  Widget build(BuildContext context) {
    final dirs = widget.dirs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Writable directories", description: widget.description),
        for (final dir in dirs)
          EditableRow(
            title: dir,
            subtitle: "",
            removeLabel: "Remove $dir",
            onTap: () => _edit(existing: dir),
            onRemove: () => _remove(dir),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add directory"),
            onPressed: () => _edit(),
          ),
        ),
      ],
    );
  }
}
