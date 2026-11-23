import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/permission_rules.dart";
import "../../app/settings/scope.dart";
import "package:entoli_chat/domain/permission.dart";
import "package:entoli_chat/domain/settings/keys.dart";
import "../widgets/add_button_row.dart";
import "package:entoli_chat/ui/widgets/busy.dart";
import "../widgets/editable_row.dart";
import "../widgets/section_header.dart";
import "scoped.dart";

/// The permission rules one level holds: a row per rule, tool and pattern on
/// it, and the add button under the list. A header is drawn where
/// [description] says whose rules these are.
class PermissionRulesSection extends ConsumerWidget {
  const PermissionRulesSection({super.key, required this.at, this.description});

  final ScopeAddress at;
  final String? description;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    final rules = scope.own(SettingKeys.permissions) ?? const [];
    Future<void> save(List<PermissionRule> next) =>
        guarded(context, () => scope.write(SettingKeys.permissions, next));
    Future<void> edit({PermissionRule? rule, int? index}) async {
      final edited = await showDialog<PermissionRule>(
        context: context,
        builder: (_) => PermissionRuleDialog(rule: rule),
      );
      if (edited == null) return;
      final next = [...rules];
      if (index != null) next.removeAt(index);
      await save(next..add(edited));
    }

    final description = this.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (description != null)
          SectionHeader("Permissions", description: description),
        for (final (index, rule) in rules.indexed)
          EditableRow(
            title: ruleTitle(rule),
            subtitle: ruleSubtitle(rule),
            removeLabel: "Remove rule",
            onTap: () => edit(rule: rule, index: index),
            onRemove: () => save([...rules]..removeAt(index)),
          ),
        AddButtonRow(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text("Add rule"),
            onPressed: () => edit(),
          ),
        ),
      ],
    );
  }
}

/// One rule, asked as three questions. Each option names an outcome, and the
/// line under it says what that means; Default is the rule leaving that
/// question to everything else. Pops with the rule on Save.
class PermissionRuleDialog extends StatefulWidget {
  const PermissionRuleDialog({super.key, this.rule});

  final PermissionRule? rule;

  @override
  State<PermissionRuleDialog> createState() => _PermissionRuleDialogState();
}

class _PermissionRuleDialogState extends State<PermissionRuleDialog> {
  late final _draft = PermissionRuleDraft(widget.rule);
  late final _pattern = TextEditingController(text: _draft.pattern);
  late final _folders = TextEditingController(text: _draft.folders);

  @override
  void dispose() {
    _pattern.dispose();
    _folders.dispose();
    super.dispose();
  }

  void _save() {
    if (_draft.problem == null) Navigator.pop(context, _draft.rule);
  }

  @override
  Widget build(BuildContext context) {
    final tool = ruleTools[_draft.tool] ?? ruleTools.values.first;
    final problem = _draft.problem;
    return AlertDialog(
      title: Text(widget.rule == null ? "Add rule" : "Edit rule"),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Question("Applies to"),
              DropdownButtonFormField<String>(
                initialValue: _draft.tool,
                isExpanded: true,
                decoration: const InputDecoration(labelText: "Tool"),
                items: [
                  for (final MapEntry(:key, :value) in ruleTools.entries)
                    DropdownMenuItem(value: key, child: Text(value.name)),
                ],
                onChanged: (value) =>
                    setState(() => _draft.tool = value ?? ruleTools.keys.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                autofocus: widget.rule == null,
                decoration: InputDecoration(
                  labelText: tool.field,
                  hintText: tool.hint,
                ),
                onChanged: (text) => setState(() => _draft.pattern = text),
                onSubmitted: (_) => _save(),
              ),
              const _Question("Before it runs"),
              _OptionField<PermissionDecision?>(
                value: _draft.decision,
                options: ruleDecisions,
                onChanged: (value) => setState(() => _draft.decision = value),
              ),
              if (_draft.asksScope) ...[
                const _Question("What it can write to"),
                _OptionField<RuleScope>(
                  value: _draft.scope,
                  options: ruleScopes,
                  onChanged: (value) => setState(
                    () => _draft.scope = value ?? RuleScope.workspaces,
                  ),
                ),
                if (_draft.scope == RuleScope.folders) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _folders,
                    decoration: InputDecoration(
                      labelText: "Folders",
                      hintText: "/run/user/1000/libpod, ~/.cache/x",
                      helperText: "Separate folders with commas.",
                      errorText: _draft.foldersMissing
                          ? "Add at least one folder, or pick another option."
                          : null,
                    ),
                    onChanged: (text) => setState(() => _draft.folders = text),
                    onSubmitted: (_) => _save(),
                  ),
                ],
              ],
              if (problem != null && problem.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  problem,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: problem == null ? _save : null,
          child: const Text("Save"),
        ),
      ],
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// A dropdown of [options] whose helper line explains the one picked.
class _OptionField<T> extends StatelessWidget {
  const _OptionField({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, RuleOption> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(
      helperText: options[value]!.help,
      helperMaxLines: 4,
    ),
    items: [
      for (final MapEntry(:key, :value) in options.entries)
        DropdownMenuItem<T>(value: key, child: Text(value.label)),
    ],
    onChanged: onChanged,
  );
}
