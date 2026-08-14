import "package:flutter/material.dart";

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
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: maxLines,
        decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        onSubmitted: maxLines == 1 ? (_) => Navigator.pop(context, submit()) : null,
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
