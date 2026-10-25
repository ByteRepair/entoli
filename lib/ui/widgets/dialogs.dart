import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../core/platform/rich_clipboard.dart";
import "../../domain/permission.dart";
import "../../domain/project.dart";
import "text_input.dart";

/// Put [text] on the clipboard and say so. Copying is silent otherwise — the
/// button that did it looks the same afterwards — so what was copied is
/// [said] in a snack bar. With [html], the same entry carries it formatted.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String said,
  String? html,
}) async {
  if (html != null) {
    await setRichClipboard(plain: text, html: html);
  } else {
    await Clipboard.setData(ClipboardData(text: text));
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
}

/// Report [error] in a snack bar. The one-line form several pages spell out
/// for a caught failure, hoisted so they stop duplicating it. Selectable, so
/// it can be copied into an issue.
void say(BuildContext context, Object error) => ScaffoldMessenger.of(context)
    .showSnackBar(SnackBar(content: SelectableText("$error")));

/// Run a [work] whose future nobody would await — a sync verb handed to an
/// `onPressed` — and catch its failure with [say], where dropping it left a
/// button that did nothing and an unhandled error. Reported only while the
/// context survives; the work itself runs whatever the tree does.
void catchAndSay(BuildContext context, Future<void> Function() work) =>
    unawaited(work().catchError((Object error) {
      if (context.mounted) say(context, error);
    }));

/// Ask which project something belongs under. The answer is wrapped because
/// the default project is null as well, and a dismissed dialog must not read
/// as picking it.
Future<({String? project})?> pickProject(
  BuildContext context, {
  required List<String?> projects,
  String? current,
}) =>
    showDialog<({String? project})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text("Move to project"),
        children: [
          for (final project in projects)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (project: project)),
              child: Row(
                children: [
                  Icon(
                    Icons.check,
                    size: 18,
                    color: project == current ? null : Colors.transparent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(projectLabel(project))),
                ],
              ),
            ),
        ],
      ),
    );

/// Tab indents where there is more than one line to indent; where the field is
/// one line it is still how the caret leaves for the buttons.
Widget _indentable(int maxLines, TextEditingController controller, Widget field) =>
    maxLines == 1 ? field : TabIndents(controller: controller, child: field);

/// Ask for a line (or a few) of text. Returns null if dismissed or, unless
/// [allowBlank], left blank — a blank answer names nothing.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String initial,
  required String confirmLabel,
  String? hint,
  int maxLines = 1,
  bool allowBlank = false,
}) {
  final controller = TextEditingController(text: initial);
  String? submit() {
    final text = controller.text.trim();
    return (text.isEmpty && !allowBlank) ? null : text;
  }

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: _indentable(
        maxLines,
        controller,
        TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: maxLines == 1 ? (_) => Navigator.pop(context, submit()) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(
          onPressed: () => Navigator.pop(context, submit()),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// Ask for a name and its value. Returns null if dismissed or if the name was
/// left blank — a value without one names nothing.
Future<({String name, String value})?> promptForPair(
  BuildContext context, {
  required String title,
  required String nameLabel,
  required String valueLabel,
  String name = "",
  String value = "",
}) {
  final nameField = TextEditingController(text: name);
  final valueField = TextEditingController(text: value);
  ({String name, String value})? submit() {
    final key = nameField.text.trim();
    return key.isEmpty ? null : (name: key, value: valueField.text.trim());
  }

  return showDialog<({String name, String value})>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameField,
            autofocus: name.isEmpty,
            decoration: InputDecoration(labelText: nameLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: valueField,
            autofocus: name.isNotEmpty,
            decoration: InputDecoration(labelText: valueLabel),
            onSubmitted: (_) => Navigator.pop(context, submit()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.pop(context, submit()), child: const Text("Save")),
      ],
    ),
  );
}

/// Ask before doing something irreversible. A null [confirmLabel] leaves only
/// a way out, for when there is nothing to confirm.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  bool destructive = false,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
        if (confirmLabel != null)
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error)
                : null,
            child: Text(confirmLabel),
          ),
      ],
    ),
  );
  return answer ?? false;
}

enum _SandboxScope { sandboxed, writes, unconfined }

/// Ask for one permission rule: the tool it names, the pattern it matches on,
/// whether a match is asked about and — for bash rules — the sandbox a match
/// runs in. Returns null if dismissed, the pattern was left blank, or the
/// rule would say nothing.
Future<PermissionRule?> promptForDecision(
  BuildContext context, {
  required String title,
  required String tool,
  required String pattern,
  required PermissionDecision? decision,
  bool unconfined = false,
  String writes = "",
}) {
  final patternField = TextEditingController(text: pattern);
  final writesField = TextEditingController(text: writes);
  var toolPicked = tool;
  var picked = decision;
  var scope = unconfined
      ? _SandboxScope.unconfined
      : writes.isEmpty
          ? _SandboxScope.sandboxed
          : _SandboxScope.writes;

  bool shapesSandbox() => toolPicked == "bash" || toolPicked == "*";

  PermissionRule? submit() {
    final subject = patternField.text.trim();
    if (subject.isEmpty) return null;
    final ruleScope = shapesSandbox() ? scope : _SandboxScope.sandboxed;
    final dirs = ruleScope != _SandboxScope.writes
        ? const <String>[]
        : [
            for (final dir in writesField.text.split(","))
              if (dir.trim().isNotEmpty) dir.trim(),
          ];
    final unconfined = ruleScope == _SandboxScope.unconfined;
    if (picked == null && !unconfined && dirs.isEmpty) return null;
    return PermissionRule(
      tool: toolPicked,
      pattern: subject,
      decision: picked,
      unconfined: unconfined,
      writes: dirs,
    );
  }

  return showDialog<PermissionRule>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: toolPicked,
              decoration: const InputDecoration(labelText: "Tool"),
              items: [
                for (final t in ["bash", "read", "write", "edit", "webfetch", "*"])
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (value) =>
                  setState(() => toolPicked = value ?? "bash"),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: patternField,
              autofocus: pattern.isEmpty,
              decoration: const InputDecoration(
                labelText: "Pattern",
                hintText: "git status *  ·  ~/Projects/x  ·  example.com",
              ),
              onSubmitted: (_) => Navigator.pop(context, submit()),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<PermissionDecision?>(
              initialValue: picked,
              decoration: const InputDecoration(labelText: "Approval"),
              items: const [
                DropdownMenuItem(
                    value: PermissionDecision.allow, child: Text("Allow")),
                DropdownMenuItem(
                    value: PermissionDecision.ask, child: Text("Ask")),
                DropdownMenuItem(
                    value: PermissionDecision.deny, child: Text("Deny")),
                DropdownMenuItem(
                    value: null, child: Text("Leave to the approval mode")),
              ],
              onChanged: (value) => setState(() => picked = value),
            ),
            if (shapesSandbox()) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<_SandboxScope>(
                initialValue: scope,
                decoration: const InputDecoration(labelText: "Sandbox"),
                items: const [
                  DropdownMenuItem(
                      value: _SandboxScope.sandboxed, child: Text("Sandboxed")),
                  DropdownMenuItem(
                      value: _SandboxScope.writes,
                      child: Text("Sandboxed, with extra writable dirs")),
                  DropdownMenuItem(
                      value: _SandboxScope.unconfined,
                      child: Text("Unconfined (no sandbox)")),
                ],
                onChanged: (value) => setState(
                    () => scope = value ?? _SandboxScope.sandboxed),
              ),
              if (scope == _SandboxScope.writes) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: writesField,
                  decoration: const InputDecoration(
                    labelText: "Extra writable dirs (comma-separated)",
                  ),
                  onSubmitted: (_) => Navigator.pop(context, submit()),
                ),
              ],
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel")),
          FilledButton(
              onPressed: () => Navigator.pop(context, submit()),
              child: const Text("Save")),
        ],
      ),
    ),
  );
}
