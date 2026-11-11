import "package:flutter/material.dart";

import "../../app/settings/controller.dart";

/// [form] as a dialog: its questions drawn again after every answer, Save
/// held while it has a problem. What it returns is the item the answers
/// make, or null where it was cancelled.
Future<T?> showSettingForm<T>(BuildContext context, SettingForm<T> form) =>
    showDialog<T>(context: context, builder: (_) => _FormDialog<T>(form));

class _FormDialog<T> extends StatefulWidget {
  const _FormDialog(this.form);

  final SettingForm<T> form;

  @override
  State<_FormDialog<T>> createState() => _FormDialogState<T>();
}

class _FormDialogState<T> extends State<_FormDialog<T>> {
  late final _answers = {...widget.form.initial};
  final _texts = <String, TextEditingController>{};

  TextEditingController _text(String id) =>
      _texts.putIfAbsent(id, () => TextEditingController(text: _answers[id]));

  @override
  void dispose() {
    for (final controller in _texts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (widget.form.problem(_answers) == null) {
      Navigator.pop(context, widget.form.build(_answers));
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = widget.form.problem(_answers);
    final fields = widget.form.fields(_answers);
    return AlertDialog(
      title: Text(widget.form.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, field) in fields.indexed) ...[
                // Two inputs in a row are spaced apart; a heading sets its
                // own space.
                if (i > 0 &&
                    field is! FormQuestion &&
                    fields[i - 1] is! FormQuestion)
                  const SizedBox(height: 12),
                _field(context, field),
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

  Widget _field(BuildContext context, FormFieldSpec field) => switch (field) {
    FormQuestion(:final text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
    FormText() => TextField(
      controller: _text(field.id),
      autofocus: field.focused,
      decoration: InputDecoration(
        labelText: field.label,
        hintText: field.hint,
        helperText: field.helper,
        errorText: field.error,
      ),
      onChanged: (text) => setState(() => _answers[field.id] = text),
      onSubmitted: (_) => _save(),
    ),
    FormChoice() => DropdownButtonFormField<String>(
      initialValue: _answers[field.id],
      isExpanded: true,
      decoration: InputDecoration(
        labelText: field.label,
        helperText: field.options
            .where((o) => o.answer == _answers[field.id])
            .firstOrNull
            ?.help,
        helperMaxLines: 4,
      ),
      items: [
        for (final option in field.options)
          DropdownMenuItem(value: option.answer, child: Text(option.label)),
      ],
      onChanged: (answer) {
        if (answer != null) setState(() => _answers[field.id] = answer);
      },
    ),
  };
}
