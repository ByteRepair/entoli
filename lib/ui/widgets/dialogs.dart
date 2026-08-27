import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../domain/project.dart";
import "text_input.dart";

/// Put [text] on the clipboard and say so. Copying is silent otherwise — the
/// button that did it looks the same afterwards — so what was copied is
/// [said] in a snack bar.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String said,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(said)));
}

/// Report [error] in a snack bar. The one-line form several pages spell out
/// for a caught failure, hoisted so they stop duplicating it.
void say(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$error")));

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

/// Ask for a line (or a few) of text. Returns null if dismissed or left blank.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String initial,
  required String confirmLabel,
  String? hint,
  int maxLines = 1,
}) {
  final controller = TextEditingController(text: initial);
  String? submit() {
    final text = controller.text.trim();
    return text.isEmpty ? null : text;
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
