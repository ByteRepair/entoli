import "package:flutter/material.dart";

import "../../domain/permission.dart";
import "../widgets/add_button_row.dart";
import "../widgets/dialogs.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";

/// The permission rules one tier holds: a row per rule, tool and pattern on
/// it, and the add button under the list. Shared by the app-level Agent
/// section and the project settings page, the way the environment editor is —
/// the tiers differ in what saves, and in nothing else.
class PermissionsSection extends StatefulWidget {
  const PermissionsSection({
    super.key,
    required this.rules,
    required this.description,
    required this.onSaved,
  });

  /// The rules as they stand, this tier alone.
  final List<PermissionRule> rules;

  /// The section's own line: whose rules these are.
  final String description;

  /// What the whole list is saved as.
  final Future<void> Function(List<PermissionRule>) onSaved;

  @override
  State<PermissionsSection> createState() => _PermissionsSectionState();
}

class _PermissionsSectionState extends State<PermissionsSection> {
  Future<void> _edit({PermissionRule? rule, int? index}) async {
    final decision = await promptForDecision(
      context,
      title: rule == null ? "Add rule" : "Edit rule",
      tool: rule?.tool ?? "bash",
      pattern: rule?.pattern ?? "",
      decision: rule == null ? PermissionDecision.allow : rule.decision,
      sandbox: rule?.sandbox ?? RuleSandbox.inherit,
      writes: (rule?.writes ?? const []).join(", "),
    );
    if (decision == null || !mounted) return;
    final next = [...widget.rules];
    if (index != null) next.removeAt(index);
    next.add(decision);
    await widget.onSaved(next);
  }

  Future<void> _remove(int index) async {
    final next = [...widget.rules]..removeAt(index);
    await widget.onSaved(next);
  }

  @override
  Widget build(BuildContext context) {
    final rules = widget.rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader("Permissions", description: widget.description),
        for (final (index, rule) in rules.indexed)
          EditableRow(
            title: "${rule.decision?.name.toUpperCase() ?? "MODE"} "
                "${rule.tool} ${rule.pattern}",
            subtitle: switch (rule.sandbox) {
              RuleSandbox.inherit => "",
              RuleSandbox.writes =>
                "sandboxed, also writes: ${rule.writes.join(", ")}",
              RuleSandbox.unconfined => "unconfined",
            },
            removeLabel: "Remove rule",
            onTap: () => _edit(rule: rule, index: index),
            onRemove: () => _remove(index),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add rule"),
            onPressed: () => _edit(),
          ),
        ),
      ],
    );
  }
}
