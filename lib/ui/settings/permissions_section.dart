import "package:flutter/material.dart";

import "../../domain/permission.dart";
import "../widgets/add_button_row.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";
import "../../app/settings/controller.dart";
import "../../app/settings/forms/permission_rule.dart";
import "form_dialog.dart";

/// The permission rules one tier holds: a row per rule, tool and pattern on
/// it, and the add button under the list. Shared by the app-level Agent
/// section and the project settings page, the way the environment editor is —
/// the tiers differ in what saves, and in nothing else.
class PermissionsSection extends StatelessWidget {
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionHeader("Permissions", description: description),
      PermissionRows(rules: rules, onSaved: onSaved),
    ],
  );
}

/// The rules under a header someone else draws: a row each, opened to edit
/// through the rule's form, and a button to add one.
class PermissionRows extends StatelessWidget {
  const PermissionRows({super.key, required this.rules, required this.onSaved});

  final List<PermissionRule> rules;
  final Future<void> Function(List<PermissionRule>) onSaved;

  Future<void> _edit(
    BuildContext context, {
    PermissionRule? rule,
    int? index,
  }) async {
    final edited = await showSettingForm(context, PermissionRuleForm(rule));
    if (edited == null || !context.mounted) return;
    final next = [...rules];
    if (index != null) next.removeAt(index);
    next.add(edited);
    await onSaved(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (index, rule) in rules.indexed)
        _row(context, describeRule(rule), index, rule),
      AddButtonRow(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text("Add rule"),
          onPressed: () => _edit(context),
        ),
      ),
    ],
  );

  Widget _row(
    BuildContext context,
    CollectionItem item,
    int index,
    PermissionRule rule,
  ) => EditableRow(
    title: item.title,
    subtitle: item.subtitle,
    removeLabel: "Remove rule",
    onTap: () => _edit(context, rule: rule, index: index),
    onRemove: () => onSaved([...rules]..removeAt(index)),
  );
}
