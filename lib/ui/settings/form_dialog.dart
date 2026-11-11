import "dart:async";

import "package:collection/collection.dart";
import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/controller.dart";
import "../../app/settings/spec.dart" show SettingGlyph;
import "../../providers.dart";
import "../widgets/discard_guard.dart";
import "../widgets/environment_section.dart";
import "../widgets/page_bar.dart";
import "../widgets/prompt_field.dart";
import "cli_sign_in_dialog.dart" show CliAccountSection;

/// [form] as a dialog, or as a page of its own where it is one: its
/// questions drawn again after every answer, Save held while it has a
/// problem. Save hands the answers to [save]; what it throws is said in the
/// form, which stays open — on the field a [FormRefusal] names, with Save
/// turned into its Save anyway. Left unsaved, the form is told. Answers
/// whether it was saved.
Future<bool> showSettingForm<T>(
  BuildContext context,
  SettingForm<T> form, {
  required Future<void> Function(Map<String, String> answers) save,
}) async {
  final session = _Session(form, save);
  final saved = form.page
      ? await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => _FormPage(session)))
      : await showDialog<bool>(
          context: context,
          builder: (_) => _FormDialog(session),
        );
  if (saved == true) return true;
  await form.dismissed(session.answers);
  return false;
}

/// [c]'s item at [index], or a new one, edited through its form and saved
/// as the controller saves it.
Future<bool> editItem<T>(
  BuildContext context,
  CollectionController<T> c, {
  int? index,
}) {
  final form = c.form;
  if (form == null) return Future.value(false);
  return showSettingForm(
    context,
    form(index == null ? null : c.items[index]),
    save: (answers) => c.submit(answers, index: index),
  );
}

/// A form being answered: what it holds now, outliving the widget that
/// draws it, so a form left unsaved is told what it was left with.
class _Session {
  _Session(this.form, this.save) : answers = {...form.initial};

  final SettingForm<Object?> form;
  final Future<void> Function(Map<String, String> answers) save;
  final Map<String, String> answers;

  late final Map<String, String> _initial = {...form.initial};

  bool get edited =>
      !const MapEquality<String, String>().equals(answers, _initial);
}

class _FormDialog extends StatelessWidget {
  const _FormDialog(this.session);

  final _Session session;

  @override
  Widget build(BuildContext context) => _FormBody(
    session,
    builder: (context, fields, save, _) => AlertDialog(
      title: Text(session.form.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(child: fields),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text("Cancel"),
        ),
        save,
      ],
    ),
  );
}

class _FormPage extends StatelessWidget {
  const _FormPage(this.session);

  final _Session session;

  @override
  Widget build(BuildContext context) => DiscardGuard(
    edited: () => session.edited,
    message: session.form.discard ?? "Throw away these edits?",
    child: _FormBody(
      session,
      page: true,
      builder: (context, fields, _, save) => Scaffold(
        appBar: PageBar(title: session.form.title, actions: [save]),
        body: ListView(padding: const EdgeInsets.all(16), children: [fields]),
      ),
    ),
  );
}

/// The fields, and the Save that goes with them: a button in a dialog, the
/// bar's action on a page.
class _FormBody extends ConsumerStatefulWidget {
  const _FormBody(this.session, {required this.builder, this.page = false});

  final _Session session;
  final bool page;

  /// The form around [fields]: [button] is Save in a dialog, [action] the
  /// same on a page's bar.
  final Widget Function(
    BuildContext context,
    Widget fields,
    Widget button,
    PageAction action,
  )
  builder;

  @override
  ConsumerState<_FormBody> createState() => _FormBodyState();
}

class _FormBodyState extends ConsumerState<_FormBody> {
  SettingForm<Object?> get _form => widget.session.form;
  Map<String, String> get _answers => widget.session.answers;

  final _texts = <String, TextEditingController>{};

  /// Why the last Save was refused, and the field it is said on, where it
  /// names one.
  String? _refused;
  String? _refusedField;

  /// The answer and the label of Save anyway, after a refusal allowing it.
  (String, String)? _anyway;
  bool _saving = false;

  TextEditingController _text(String id) =>
      _texts.putIfAbsent(id, () => TextEditingController(text: _answers[id]));

  @override
  void dispose() {
    for (final controller in _texts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _answer(String id, String value) => setState(() {
    _answers[id] = value;
    if (id == _refusedField) {
      _refused = null;
      _refusedField = null;
      if (_anyway case (final answer, _)) _answers.remove(answer);
      _anyway = null;
    }
  });

  Future<void> _save() async {
    if (_saving || _form.problem(_answers) != null) return;
    if (_anyway case (final answer, _)) _answers[answer] = "yes";
    setState(() {
      _saving = true;
      _refused = null;
      _refusedField = null;
    });
    try {
      await widget.session.save({..._answers});
      if (mounted) Navigator.pop(context, true);
    } on FormRefusal catch (e) {
      if (!mounted) return;
      setState(() {
        _refused = e.message;
        _refusedField = e.field;
        _anyway = switch ((e.anyway, e.anywayLabel)) {
          (final answer?, final label?) => (answer, label),
          _ => null,
        };
      });
    } catch (e) {
      if (mounted) setState(() => _refused = "$e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _form.problem(_answers);
    final fields = _form.fields(_answers);
    final label = _anyway?.$2 ?? "Save";
    final ready = problem == null && !_saving;
    void Function()? press = ready ? () => unawaited(_save()) : null;
    final button = FilledButton(
      onPressed: press,
      child: _saving
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
    final action = PageAction.text(label: label, onPressed: press);
    final unplaced = _refusedField == null ? _refused : null;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, field) in fields.indexed) ...[
          // Two inputs in a row are spaced apart; a heading sets its own
          // space.
          if (i > 0 && field is! FormQuestion && fields[i - 1] is! FormQuestion)
            const SizedBox(height: 12),
          _field(context, field),
        ],
        if (problem != null && problem.isNotEmpty || unplaced != null) ...[
          const SizedBox(height: 16),
          Text(
            unplaced ?? problem!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
    return widget.builder(context, body, button, action);
  }

  String? _error(String id, String? own) =>
      id == _refusedField ? _refused : own;

  Widget _field(BuildContext context, FormFieldSpec field) {
    final theme = Theme.of(context);
    return switch (field) {
      FormQuestion(:final text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(text, style: theme.textTheme.titleSmall),
      ),
      FormNote(:final text) => Text(text, style: theme.textTheme.bodyMedium),
      FormText() => TextField(
        controller: _text(field.id),
        enabled: field.enabled,
        autofocus: field.focused,
        obscureText: field.secret,
        minLines: field.lines > 1 ? field.lines : null,
        maxLines: field.lines > 1 ? null : 1,
        decoration: InputDecoration(
          labelText: field.label,
          hintText: field.hint,
          helperText: field.helper,
          helperMaxLines: 3,
          errorText: _error(field.id, field.error),
          errorMaxLines: 2,
          suffixIcon: field.file
              ? IconButton(
                  tooltip: "Choose a file",
                  icon: const Icon(Icons.folder_open),
                  onPressed: field.enabled ? () => _pick(field.id) : null,
                )
              : null,
        ),
        onChanged: (text) => _answer(field.id, text),
        onSubmitted: (_) => unawaited(_save()),
      ),
      FormPrompt() => PromptField(
        label: field.label,
        value: _answers[field.id] ?? "",
        hint: field.hint ?? "",
        project: field.project,
        editable: field.enabled,
        padding: EdgeInsets.zero,
        onChanged: (text) => _answer(field.id, text),
      ),
      FormChoice(cards: true) => _Cards(
        field: field,
        onPick: (answer) => _answer(field.id, answer),
      ),
      FormChoice(segmented: true) => SegmentedButton<String>(
        segments: [
          for (final option in field.options)
            ButtonSegment(value: option.answer, label: Text(option.label)),
        ],
        selected: {?_answers[field.id]},
        onSelectionChanged: field.enabled
            ? (picked) => _answer(field.id, picked.first)
            : null,
      ),
      FormChoice() => DropdownButtonFormField<String>(
        // Keyed by the answer, so an answer set elsewhere is drawn.
        key: ValueKey((field.id, _answers[field.id])),
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
                if (answer != null) _answer(field.id, answer);
              }
            : null,
      ),
      FormLink(:final label, :final url, :final prominent) =>
        prominent
            ? FilledButton.tonalIcon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(label),
                onPressed: () => _open(url),
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => _open(url),
                  child: Text(label),
                ),
              ),
      FormFold(:final id, :final label) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          icon: Icon(
            _answers[id] == "open" ? Icons.expand_less : Icons.expand_more,
          ),
          label: Text(label),
          onPressed: () => _answer(id, _answers[id] == "open" ? "" : "open"),
        ),
      ),
      FormConsent() => _Consent(
        field: field,
        onOpen: _open,
        onAccept: () => _answer(field.id, "yes"),
      ),
      FormEntries() => EnvironmentSection(
        env: {
          for (final line in (_answers[field.id] ?? "").split("\n"))
            if (line.indexOf("=") case final at when at > 0)
              line.substring(0, at): line.substring(at + 1),
        },
        description: field.helper ?? "",
        onSaved: (env) async => _answer(
          field.id,
          [
            for (final MapEntry(:key, :value) in env.entries) "$key=$value",
          ].join("\n"),
        ),
      ),
      // Keyed by the program, so switching the API asks the other one.
      FormSignIn(:final config) => CliAccountSection(
        key: ValueKey(config.api),
        config: config,
      ),
      FormDate() => _DateField(
        label: field.label,
        value: DateTime.tryParse(_answers[field.id] ?? "") ?? DateTime.now(),
        onChanged: field.enabled
            ? (at) => _answer(field.id, at.toIso8601String())
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
        onChanged: (text) => _answer(field.id, text),
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
        onChanged: (text) => _answer(field.id, text),
      ),
      FormMulti() => _Multi(
        field: field,
        picked: {
          for (final answer in (_answers[field.id] ?? "").split(","))
            if (answer.isNotEmpty) answer,
        },
        onChanged: (picked) => _answer(field.id, picked.join(",")),
      ),
    };
  }

  void _open(Uri url) => ref.read(linkOpenerProvider).open(context, url);

  Future<void> _pick(String id) async {
    final file = await openFile(confirmButtonText: "Use this file");
    if (file == null || !mounted) return;
    _text(id).text = file.path;
    _answer(id, file.path);
  }
}

/// A choice as a card per option, under its group: what it is, and its tags.
class _Cards extends StatelessWidget {
  const _Cards({required this.field, required this.onPick});

  final FormChoice field;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final options = field.options;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, option) in options.indexed) ...[
          // A heading where a group starts, and a rule above what is in
          // none.
          if (option.group != (i == 0 ? null : options[i - 1].group))
            if (option.group case final group?)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                child: Text(
                  group,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.primary,
                  ),
                ),
              )
            else
              const Divider(),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: colors.secondaryContainer,
              foregroundColor: colors.onSecondaryContainer,
              child: Icon(_glyph(option)),
            ),
            title: Text(option.label),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (option.help case final help?) Text(help),
                if (option.tags.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [for (final tag in option.tags) _Tag(tag)],
                  ),
                ],
              ],
            ),
            isThreeLine: option.help != null,
            enabled: field.enabled,
            onTap: () => onPick(option.answer),
          ),
        ],
      ],
    );
  }

  static IconData _glyph(FormOption option) => switch (option.glyph) {
    SettingGlyph.terminal => Icons.terminal,
    SettingGlyph.computer => Icons.computer,
    SettingGlyph.tune => Icons.tune,
    _ => Icons.cloud_outlined,
  };
}

class _Tag extends StatelessWidget {
  const _Tag(this.tag);

  final FormTag tag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tag.tone) {
      NoticeTone.plain => (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      NoticeTone.good => (colors.primaryContainer, colors.onPrimaryContainer),
      NoticeTone.warning => (colors.errorContainer, colors.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        // Not a full pill: on a narrow screen the label wraps to two lines.
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tag.text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// What has to be agreed to before the rest is asked.
class _Consent extends StatelessWidget {
  const _Consent({
    required this.field,
    required this.onOpen,
    required this.onAccept,
  });

  final FormConsent field;
  final ValueChanged<Uri> onOpen;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.privacy_tip_outlined, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(field.title, style: theme.textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(field.message),
        if (field.link case (final label, final url)) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(label),
            onPressed: () => onOpen(url),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onAccept,
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(field.accept),
          ),
        ),
      ],
    );
  }
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

/// Any of a field's options: a switch each, with what it is under it, where
/// the options say; chips where they are only names. A field over all of
/// them leads with the switch that takes the lot.
class _Multi extends StatelessWidget {
  const _Multi({
    required this.field,
    required this.picked,
    required this.onChanged,
  });

  final FormMulti field;
  final Set<String> picked;
  final ValueChanged<Set<String>> onChanged;

  ValueChanged<bool>? _set(String answer) => field.enabled
      ? (on) => onChanged(field.toggled(picked, answer, on))
      : null;

  @override
  Widget build(BuildContext context) {
    final explained = field.options.any((o) => o.help != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (field.all)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(field.label),
            value: field.allOn(picked),
            onChanged: field.enabled
                ? (on) => onChanged(field.withAll(picked, on))
                : null,
          )
        else ...[
          Text(field.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
        ],
        if (explained)
          for (final option in field.options)
            SwitchListTile(
              dense: field.all,
              contentPadding: EdgeInsets.only(left: field.all ? 16 : 0),
              title: Text(option.label),
              subtitle: option.help == null
                  ? null
                  : Text(
                      option.help!,
                      maxLines: field.all ? 2 : null,
                      overflow: field.all ? TextOverflow.ellipsis : null,
                    ),
              value: picked.contains(option.answer),
              onChanged: _set(option.answer),
            )
        else
          Wrap(
            spacing: 8,
            children: [
              for (final option in field.options)
                FilterChip(
                  label: Text(option.label),
                  selected: picked.contains(option.answer),
                  onSelected: _set(option.answer),
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
}
