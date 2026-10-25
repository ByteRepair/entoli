import "package:flutter/material.dart";

import "../../domain/permission.dart";
import "../widgets/add_button_row.dart";
import "../widgets/editable_row.dart";
import "../widgets/resettable_field.dart" show defaultOptionLabel;
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
    final edited = await showDialog<PermissionRule>(
      context: context,
      builder: (_) => _RuleDialog(rule: rule),
    );
    if (edited == null || !mounted) return;
    final next = [...widget.rules];
    if (index != null) next.removeAt(index);
    next.add(edited);
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
            title: "${_tools[rule.tool]?.name ?? rule.tool}: ${rule.pattern}",
            subtitle: [
              if (rule.decision case final decision?)
                _decisions[decision]!.label,
              if (rule.setsSandbox)
                switch (_scopeOf(rule)) {
                  _Scope.workspaces => null,
                  _Scope.folders => "Also writes to: ${rule.writes.join(", ")}",
                  _Scope.anywhere => "No sandbox",
                },
            ].nonNulls.join(" · "),
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

/// Per tool: what it is called, with its own name beside it, and what the
/// pattern field matches for it — a command, a path or a host.
typedef _Tool = ({String name, String field, String hint});

const Map<String, _Tool> _tools = {
  "bash": (
    name: "Shell commands (bash)",
    field: "Command",
    hint: "podman *   (* matches any arguments)",
  ),
  "read": (name: "Reading files (read)", field: "File or folder", hint: "~/Projects/x"),
  "write": (name: "Writing files (write)", field: "File or folder", hint: "~/Projects/x"),
  "edit": (name: "Editing files (edit)", field: "File or folder", hint: "~/Projects/x"),
  "webfetch": (
    name: "Web fetches (webfetch)",
    field: "Domain",
    hint: "example.com   (subdomains included)",
  ),
  "*": (
    name: "Every tool (*)",
    field: "Pattern",
    hint: "a command, a path or a domain",
  ),
};

typedef _Option = ({String label, String help});

/// Null is the rule saying nothing, so the approval mode decides.
const Map<PermissionDecision?, _Option> _decisions = {
  null: (
    label: "$defaultOptionLabel (the approval mode decides)",
    help: "This rule doesn't change it: the approval mode in Settings "
        "decides, as for any other command (ask every time, let the "
        "classifier decide, or run everything). Pick this when the rule is "
        "only about what the command can write to.",
  ),
  PermissionDecision.allow: (
    label: "Run without asking",
    help: "Runs straight away, without the approval banner or the "
        "classifier.",
  ),
  PermissionDecision.ask: (
    label: "Ask me first",
    help: "Always shows the approval banner, even where the classifier or "
        "another rule would have let it through.",
  ),
  PermissionDecision.deny: (
    label: "Block it",
    help: "Never runs. The agent is told the call was blocked by a rule.",
  ),
};

/// The dialog's view of a rule's sandbox, which the rule holds as
/// `unconfined` and `writes`.
enum _Scope { workspaces, folders, anywhere }

_Scope _scopeOf(PermissionRule rule) => rule.unconfined
    ? _Scope.anywhere
    : rule.writes.isEmpty
        ? _Scope.workspaces
        : _Scope.folders;

const Map<_Scope, _Option> _scopes = {
  _Scope.workspaces: (
    label: "$defaultOptionLabel (workspaces only)",
    help: "This rule doesn't change it: the command can write inside the "
        "chat and project workspaces and the project's writable "
        "directories. Everywhere else is read-only. Reading is never "
        "blocked.",
  ),
  _Scope.folders: (
    label: "Workspaces and these folders",
    help: "The default, plus the folders below, for the commands this rule "
        "matches only.",
  ),
  _Scope.anywhere: (
    label: "Anywhere (no sandbox)",
    help: "Runs with your full user permissions, as in your own terminal. "
        "For tools like podman or toolbox that write to system or runtime "
        "folders.",
  ),
};

/// One rule, asked as three questions: which calls it applies to, what
/// happens before one runs, and what a command can write to once it does.
/// Each option names an outcome, and the line under it says what that means;
/// Default is the rule leaving that question to everything else.
class _RuleDialog extends StatefulWidget {
  const _RuleDialog({this.rule});

  final PermissionRule? rule;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _pattern = TextEditingController(text: widget.rule?.pattern);
  late final _folders =
      TextEditingController(text: widget.rule?.writes.join(", "));
  late var _tool = widget.rule?.tool ?? "bash";
  late var _decision = widget.rule == null
      ? PermissionDecision.allow
      : widget.rule!.decision;
  late var _scope =
      widget.rule == null ? _Scope.workspaces : _scopeOf(widget.rule!);

  @override
  void dispose() {
    _pattern.dispose();
    _folders.dispose();
    super.dispose();
  }

  /// Whether the write question applies: a command, and not a blocked one.
  /// [_scope] is kept while it does not, so switching back restores it.
  bool get _asksScope =>
      PermissionRule.takesSandbox(_tool) && _decision != PermissionDecision.deny;

  List<String> get _folderList => [
        for (final dir in _folders.text.split(","))
          if (dir.trim().isNotEmpty) dir.trim(),
      ];

  bool get _foldersMissing =>
      _asksScope && _scope == _Scope.folders && _folderList.isEmpty;

  /// Why Save is off, or null where it is on. Empty where a field already
  /// says so, or where there is nothing to say yet.
  String? _problem(PermissionRule rule) {
    if (rule.pattern.isEmpty || _foldersMissing) return "";
    if (rule.saysNothing) {
      return "With both on Default, this rule would change nothing.";
    }
    return null;
  }

  PermissionRule _rule() {
    final scope = _asksScope ? _scope : _Scope.workspaces;
    return PermissionRule(
      tool: _tool,
      pattern: _pattern.text.trim(),
      decision: _decision,
      unconfined: scope == _Scope.anywhere,
      writes: scope == _Scope.folders ? _folderList : const [],
    );
  }

  void _save() {
    final rule = _rule();
    if (_problem(rule) == null) Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final tool = _tools[_tool]!;
    final problem = _problem(_rule());
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
                initialValue: _tool,
                isExpanded: true,
                decoration: const InputDecoration(labelText: "Tool"),
                items: [
                  for (final MapEntry(:key, :value) in _tools.entries)
                    DropdownMenuItem(value: key, child: Text(value.name)),
                ],
                onChanged: (value) => setState(() => _tool = value ?? "bash"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                autofocus: widget.rule == null,
                decoration: InputDecoration(
                  labelText: tool.field,
                  hintText: tool.hint,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              const _Question("Before it runs"),
              _OptionField<PermissionDecision?>(
                value: _decision,
                options: _decisions,
                onChanged: (value) => setState(() => _decision = value),
              ),
              if (_asksScope) ...[
                const _Question("What it can write to"),
                _OptionField<_Scope>(
                  value: _scope,
                  options: _scopes,
                  onChanged: (value) =>
                      setState(() => _scope = value ?? _Scope.workspaces),
                ),
                if (_scope == _Scope.folders) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _folders,
                    decoration: InputDecoration(
                      labelText: "Folders",
                      hintText: "/run/user/1000/libpod, ~/.cache/x",
                      helperText: "Separate folders with commas.",
                      errorText: _foldersMissing
                          ? "Add at least one folder, or pick another option."
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
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
            child: const Text("Cancel")),
        FilledButton(
            onPressed: problem == null ? _save : null,
            child: const Text("Save")),
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
  final Map<T, _Option> options;
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
