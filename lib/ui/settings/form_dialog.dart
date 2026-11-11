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
    FormNote(:final text) => Text(
      text,
      style: const TextStyle(fontStyle: FontStyle.italic),
    ),
    FormText() => TextField(
      controller: _text(field.id),
      enabled: field.enabled,
      autofocus: field.focused,
      minLines: field.lines > 1 ? field.lines : null,
      maxLines: field.lines > 1 ? null : 1,
      decoration: InputDecoration(
        labelText: field.label,
        hintText: field.hint,
        helperText: field.helper,
        errorText: field.error,
      ),
      onChanged: (text) => setState(() => _answers[field.id] = text),
      onSubmitted: (_) => _save(),
    ),
    FormChoice(segmented: true) => SegmentedButton<String>(
      segments: [
        for (final option in field.options)
          ButtonSegment(value: option.answer, label: Text(option.label)),
      ],
      selected: {?_answers[field.id]},
      onSelectionChanged: field.enabled
          ? (picked) => setState(() => _answers[field.id] = picked.first)
          : null,
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
      onChanged: field.enabled
          ? (answer) {
              if (answer != null) setState(() => _answers[field.id] = answer);
            }
          : null,
    ),
    FormDate() => _DateField(
      label: field.label,
      value: DateTime.tryParse(_answers[field.id] ?? "") ?? DateTime.now(),
      onChanged: field.enabled
          ? (at) => setState(() => _answers[field.id] = at.toIso8601String())
          : null,
    ),
    FormDuration() => TextField(
      controller: _text(field.id),
      enabled: field.enabled,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: "${field.label} (minutes)",
        helperText: field.helper,
      ),
      onChanged: (text) => setState(() => _answers[field.id] = text),
    ),
    FormList() => TextField(
      controller: _text(field.id),
      enabled: field.enabled,
      minLines: 2,
      maxLines: null,
      decoration: InputDecoration(
        labelText: field.label,
        hintText: field.hint,
        helperText: field.helper,
        helperMaxLines: 3,
        errorText: field.error,
      ),
      onChanged: (text) => setState(() => _answers[field.id] = text),
    ),
    FormMulti() => _Multi(
      field: field,
      picked: {
        for (final answer in (_answers[field.id] ?? "").split(","))
          if (answer.isNotEmpty) answer,
      },
      onChanged: (picked) =>
          setState(() => _answers[field.id] = picked.join(",")),
    ),
  };
}

/// A moment picked as a date and then a time.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime value;
  final ValueChanged<DateTime>? onChanged;

  Future<void> _pick(BuildContext context) async {
    final day = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (day == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null) return;
    onChanged?.call(
      DateTime(day.year, day.month, day.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(MaterialLocalizations.of(context).formatFullDate(value)),
    trailing: Text(TimeOfDay.fromDateTime(value).format(context)),
    onTap: onChanged == null ? null : () => _pick(context),
  );
}

/// Any of a field's options, as chips.
class _Multi extends StatelessWidget {
  const _Multi({
    required this.field,
    required this.picked,
    required this.onChanged,
  });

  final FormMulti field;
  final Set<String> picked;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(field.label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        children: [
          for (final option in field.options)
            FilterChip(
              label: Text(option.label),
              selected: picked.contains(option.answer),
              onSelected: field.enabled
                  ? (on) => onChanged(
                      on
                          ? {...picked, option.answer}
                          : ({...picked}..remove(option.answer)),
                    )
                  : null,
            ),
        ],
      ),
      if (field.error case final error?)
        Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
