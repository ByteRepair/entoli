import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/triggers.dart";
import "package:entoli_chat/domain/date_words.dart" show shortDate, timeOfDay;
import "package:entoli_chat/domain/models.dart" show CompletionKind;
import "package:entoli_chat/domain/project.dart";
import "package:entoli_chat/domain/trigger.dart";
import "../../providers.dart";
import "package:entoli_chat/ui/widgets/busy.dart";
import "package:entoli_chat/ui/widgets/dialogs.dart"
    show confirm, promptForText;
import "package:entoli_chat/ui/widgets/discard_guard.dart";
import "package:entoli_chat/ui/widgets/notice.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";
import "../widgets/prompt_field.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/temp_chat_ttl_field.dart";

/// The Triggers category: a prompt that a schedule, a countdown or a file
/// change sends to a chat. Where the platform has no clock to fire one the
/// category is not listed.
class TriggersSection extends ConsumerWidget {
  const TriggersSection({super.key});

  Future<void> _openEditor(BuildContext context, [Trigger? trigger]) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TriggerEditorPage(trigger: trigger)),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarms = ref.watch(reminderAlarmsProvider);
    final triggers = ref.watch(triggersProvider);
    final allowed = ref.watch(triggerPermissionsProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Triggers",
          description: alarms.schedules
              ? "A trigger sends its prompt to a chat: at a time you pick, "
                    "after a countdown, or when a file changes. A schedule "
                    "fires even when the app is closed; a countdown or a file "
                    "change needs it running."
              : "A trigger sends its prompt to a chat: at a time you pick, "
                    "after a countdown, or when a file changes. The app has to "
                    "be running for one to fire; one missed while it was closed "
                    "is caught up at the next launch.",
        ),
        if (allowed?.notifications == false)
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text("Notifications are off"),
            subtitle: const Text("Allow them to see when a trigger finishes."),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => guarded(context, alarms.requestNotifications),
          ),
        if (allowed?.exact == false)
          ListTile(
            leading: const Icon(Icons.alarm_off_outlined),
            title: const Text("Exact times are not granted"),
            subtitle: const Text(
              "Without them a schedule may fire minutes late, and its turn can "
              "be cut short while the app is closed.",
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => guarded(context, alarms.requestExact),
          ),
        for (final trigger in triggers)
          _TriggerTile(
            trigger: trigger,
            exact: allowed?.exact != false,
            onEdit: () => _openEditor(context, trigger),
          ),
        ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text("Add trigger"),
          onTap: () => _openEditor(context),
        ),
      ],
    );
  }
}

/// One trigger as a row: what and when, with the switch that arms it.
class _TriggerTile extends ConsumerWidget {
  const _TriggerTile({
    required this.trigger,
    required this.exact,
    required this.onEdit,
  });

  final Trigger trigger;
  final bool exact;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = triggerSummary(
      trigger,
      projects: ref.watch(projectListProvider).value ?? const [],
      now: ref.watch(clockProvider).now(),
      exact: exact,
    );
    return ListTile(
      leading: Icon(switch (trigger.source) {
        ScheduleSource() => Icons.schedule_outlined,
        TimerSource() => Icons.timer_outlined,
        FileSource() => Icons.insert_drive_file_outlined,
      }),
      title: Text(trigger.label),
      subtitle: Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Switch(
        value: trigger.enabled,
        onChanged: (enabled) => guarded(
          context,
          () => ref
              .read(triggersProvider.notifier)
              .setEnabled(trigger.id, enabled),
        ),
      ),
      onTap: onEdit,
    );
  }
}

/// The add and edit page. The prompt is shown as the message it will send
/// rather than as a box to type in: writing it is [PromptPage]'s.
///
/// A trigger the agent registered opens read-only: the prompt is the
/// conversation's, and the delete and the list's switch are what is left.
class TriggerEditorPage extends ConsumerStatefulWidget {
  const TriggerEditorPage({super.key, this.trigger});

  final Trigger? trigger;

  @override
  ConsumerState<TriggerEditorPage> createState() => _TriggerEditorPageState();
}

class _TriggerEditorPageState extends ConsumerState<TriggerEditorPage> {
  late final _draft = TriggerDraft(
    widget.trigger,
    now: ref.read(clockProvider).now(),
  );
  late final _name = TextEditingController(text: _draft.name);
  final _saving = ValueNotifier(false);

  @override
  void dispose() {
    _name.dispose();
    _saving.dispose();
    super.dispose();
  }

  void _edit(void Function(TriggerDraft draft) change) =>
      setState(() => change(_draft));

  @override
  Widget build(BuildContext context) {
    // Null until it loads, when the trigger's own project stands: resolved
    // against no list, it would read as the default.
    final named = ref.watch(projectListProvider).value;
    final project = named == null
        ? _draft.project
        : projectOrDefault(_draft.project, named);
    final registered = _draft.registered;
    final editable = !registered;
    final refusal = _draft.refusal;
    final theme = Theme.of(context);
    return DiscardGuard(
      edited: () => _draft.edited,
      message: "Throw away the edits to this trigger?",
      child: Scaffold(
        appBar: PageBar(
          title: _draft.isNew ? "New trigger" : "Edit trigger",
          actions: [
            if (!_draft.isNew)
              PageAction.icon(
                icon: Icons.delete_outline,
                label: "Delete trigger",
                onPressed: _delete,
              ),
            // Anything saved from here would rewrite what the agent's
            // conversation armed, from a page whose prompt it may not touch.
            if (editable)
              PageAction.text(
                label: "Save",
                onPressed: refusal == null ? _save : null,
              ),
          ],
        ),
        body: ListView(
          children: [
            BusyBar(_saving),
            if (registered)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  "This trigger was set by the agent in its chat. Switch it "
                  "off or delete it; the prompt is the conversation's.",
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              )
            else if (refusal != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  refusal,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _name,
                enabled: editable,
                onChanged: (name) => _draft.name = name,
                decoration: const InputDecoration(labelText: "Name"),
              ),
            ),
            LabelledField(
              label: "When",
              child: SegmentedButton<TriggerKind>(
                segments: const [
                  ButtonSegment(
                    value: TriggerKind.schedule,
                    label: Text("Time"),
                  ),
                  ButtonSegment(
                    value: TriggerKind.timer,
                    label: Text("Countdown"),
                  ),
                  ButtonSegment(value: TriggerKind.file, label: Text("Files")),
                ],
                selected: {_draft.kind},
                onSelectionChanged: editable
                    ? (picked) => _edit((d) => d.kind = picked.first)
                    : null,
              ),
            ),
            ..._sourceFields(editable),
            _memberField(editable),
            PromptField(
              label: "Prompt",
              value: _draft.prompt,
              hint: "What should the agent do?",
              project: _draft.project,
              editable: editable,
              onChanged: (prompt) => _edit((d) => d.prompt = prompt),
            ),
            const Divider(height: 1),
            if (editable) ...[
              TempChatTtlField(
                value: _draft.tempChatTtl,
                onChanged: (ttl) => _edit((d) => d.tempChatTtl = ttl),
                project: project,
              ),
              if (named != null)
                LabelledField(
                  label: "Project",
                  child: DropdownButtonFormField<String?>(
                    initialValue: project,
                    isExpanded: true,
                    items: [
                      for (final project in everyProject(named))
                        DropdownMenuItem(
                          value: project,
                          child: Text(projectLabel(project)),
                        ),
                    ],
                    onChanged: (project) => _edit((d) => d.project = project),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Who a fire is addressed to. A project's own agents over the inherited
  /// ones; a stored member the library has since lost stays named, with a
  /// line saying what a fire will do about it, since clearing it silently
  /// would rewrite what was armed.
  Widget _memberField(bool editable) {
    final members = ref
        .watch(promptLibraryProvider(_draft.project))
        .entries(CompletionKind.agent)
        .map((e) => e.name)
        .toList();
    final member = _draft.member;
    final vanished = member != null && !members.contains(member);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabelledField(
          label: "Address to",
          child: DropdownButtonFormField<String?>(
            initialValue: member,
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text("The whole room"),
              ),
              if (vanished)
                DropdownMenuItem(
                  value: member,
                  child: Text("@$member (deleted)"),
                ),
              for (final name in members)
                DropdownMenuItem(value: name, child: Text("@$name")),
            ],
            onChanged: editable
                ? (picked) => _edit((d) => d.member = picked)
                : null,
          ),
        ),
        if (vanished)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              "This agent no longer exists; a fire will reach the whole room.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// The rows the kind picked needs: date and time, countdown minutes, or
  /// paths and their events.
  List<Widget> _sourceFields(bool editable) => switch (_draft.source) {
    ScheduleSource(:final at, :final repeat) => [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: editable ? _pickDate : null,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(shortDate(at)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: editable ? _pickTime : null,
                icon: const Icon(Icons.schedule_outlined, size: 18),
                label: Text(timeOfDay(at)),
              ),
            ),
          ],
        ),
      ),
      LabelledField(
        label: "Repeat",
        child: DropdownButtonFormField<ScheduleRepeat>(
          initialValue: repeat,
          isExpanded: true,
          items: [
            for (final repeat in ScheduleRepeat.values)
              DropdownMenuItem(value: repeat, child: Text(repeat.label)),
          ],
          onChanged: editable
              ? (picked) => _edit(
                  (d) => d.source = ScheduleSource(
                    at: at,
                    repeat: picked ?? ScheduleRepeat.off,
                  ),
                )
              : null,
        ),
      ),
    ],
    final TimerSource timer => [
      ListTile(
        leading: const Icon(Icons.timer_outlined),
        title: Text(timer.describe()),
        subtitle: const Text("From being saved"),
        onTap: editable ? () => _pickDuration(timer.duration) : null,
      ),
    ],
    final FileSource files => [
      _FileSourceField(
        source: files,
        onChanged: editable
            ? (source) => _edit((d) => d.source = source)
            : null,
      ),
    ],
  };

  Future<void> _pickDuration(Duration current) async {
    final minutes = await promptForText(
      context,
      title: "Countdown",
      initial: "${current.inMinutes}",
      confirmLabel: "Set",
      hint: "Minutes",
    );
    if (!mounted || minutes == null) return;
    final parsed = int.tryParse(minutes.trim());
    if (parsed == null || parsed <= 0) {
      say(context, "Set a countdown of at least a minute.");
      return;
    }
    _edit(
      (d) => d.source = TimerSource(
        duration: Duration(minutes: parsed),
        registeredAt: d.now,
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = ref.read(clockProvider).now();
    final source = _draft.source as ScheduleSource;
    final at = source.at;
    // A repeating schedule keeps the day it was first set for, which can be
    // past the year back the picker otherwise offers; it asserts against an
    // initial date outside its range.
    final yearAgo = now.subtract(const Duration(days: 365));
    final last = now.add(const Duration(days: 365 * 5));
    final picked = await showDatePicker(
      context: context,
      initialDate: at,
      firstDate: at.isBefore(yearAgo) ? at : yearAgo,
      lastDate: at.isAfter(last) ? at : last,
    );
    if (picked == null || !mounted) return;
    _edit(
      (d) => d.source = ScheduleSource(
        at: DateTime(picked.year, picked.month, picked.day, at.hour, at.minute),
        repeat: source.repeat,
      ),
    );
  }

  Future<void> _pickTime() async {
    final source = _draft.source as ScheduleSource;
    final at = source.at;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(at),
    );
    if (picked == null || !mounted) return;
    _edit(
      (d) => d.source = ScheduleSource(
        at: DateTime(at.year, at.month, at.day, picked.hour, picked.minute),
        repeat: source.repeat,
      ),
    );
  }

  Future<void> _save() => whileBusy(context, _saving, () async {
    final made = _draft.build(
      at: ref.read(clockProvider).now(),
      projects: ref.read(projectListProvider).value,
    );
    final notifier = ref.read(triggersProvider.notifier);
    await (_draft.isNew ? notifier.add(made) : notifier.replace(made));
    if (mounted) Navigator.of(context).pop();
  });

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: "Delete trigger",
      message: "Delete this trigger?",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok || !mounted) return;
    await whileBusy(context, _saving, () async {
      await ref.read(triggersProvider.notifier).remove(widget.trigger!.id);
      if (mounted) Navigator.of(context).pop();
    });
  }
}

/// The file source's rows: one path at a time and the kinds of change to
/// fire on. The paths are typed the way the file tools read them, in the
/// chat's workspace or `project:`-prefixed, since the watch resolves them
/// exactly there.
class _FileSourceField extends StatefulWidget {
  const _FileSourceField({required this.source, required this.onChanged});

  final FileSource source;

  /// Null where the rows are read-only.
  final void Function(FileSource)? onChanged;

  @override
  State<_FileSourceField> createState() => _FileSourceFieldState();
}

class _FileSourceFieldState extends State<_FileSourceField> {
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _add(String text) {
    final path = text.trim();
    if (path.isEmpty || widget.source.paths.contains(path)) return;
    _emit(paths: [...widget.source.paths, path]);
    _path.clear();
  }

  void _emit({List<String>? paths, Set<FileEvent>? events}) {
    final source = widget.source;
    widget.onChanged?.call(
      FileSource(
        paths: paths ?? source.paths,
        events: events ?? source.events,
        cooldown: source.cooldown,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final editable = widget.onChanged != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _path,
                  enabled: editable,
                  decoration: const InputDecoration(
                    labelText: "Path to watch",
                    hintText: "build.log, or project:notes/",
                  ),
                  onSubmitted: _add,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: "Add path",
                onPressed: editable ? () => _add(_path.text) : null,
              ),
            ],
          ),
        ),
        for (final path in source.paths)
          ListTile(
            dense: true,
            leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
            title: Text(path),
            trailing: editable
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Remove path",
                    onPressed: () =>
                        _emit(paths: [...source.paths]..remove(path)),
                  )
                : null,
          ),
        LabelledField(
          label: "Fire on",
          child: Wrap(
            spacing: 8,
            children: [
              for (final event in FileEvent.values)
                FilterChip(
                  label: Text(event.label),
                  selected: source.events.contains(event),
                  onSelected: editable
                      ? (on) => _emit(
                          events: on
                              ? {...source.events, event}
                              : ({...source.events}..remove(event)),
                        )
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
