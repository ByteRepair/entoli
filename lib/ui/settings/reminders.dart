import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/project.dart";
import "../../domain/reminder.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart" show confirm;
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/text_input.dart";

/// The Reminders category. Android's feature — the system clock is what fires
/// a reminder with the app closed, and nothing here can wake any other
/// platform — so where the port is unavailable the page says so and offers
/// nothing, the way a row for a missing device would.
class RemindersSection extends ConsumerStatefulWidget {
  const RemindersSection({super.key});

  @override
  ConsumerState<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends ConsumerState<RemindersSection> {
  bool? _notificationsAllowed;
  bool? _exactAllowed;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPermissions());
  }

  Future<void> _loadPermissions() async {
    final alarms = ref.read(reminderAlarmsProvider);
    if (!alarms.available) return;
    final notifications = await alarms.notificationsAllowed();
    final exact = await alarms.exactAllowed();
    if (!mounted) return;
    setState(() {
      _notificationsAllowed = notifications;
      _exactAllowed = exact;
    });
  }

  Future<void> _openEditor([Reminder? reminder]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReminderEditorPage(reminder: reminder)),
    );
    await _loadPermissions();
  }

  @override
  Widget build(BuildContext context) {
    final alarms = ref.watch(reminderAlarmsProvider);
    if (!alarms.available) return const _Unavailable();
    final reminders = ref.watch(remindersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          "Reminders",
          description: "A reminder runs its prompt in a new chat at a time you "
              "pick, even when the app is closed.",
        ),
        if (_notificationsAllowed == false)
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text("Notifications are off"),
            subtitle: const Text("Allow them to see when a reminder finishes."),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ref.read(reminderAlarmsProvider).requestNotifications();
              await _loadPermissions();
            },
          ),
        if (_exactAllowed == false)
          ListTile(
            leading: const Icon(Icons.alarm_off_outlined),
            title: const Text("Exact times are not granted"),
            subtitle: const Text("Without them reminders may fire minutes late."),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await ref.read(reminderAlarmsProvider).requestExact();
              await _loadPermissions();
            },
          ),
        for (final reminder in reminders)
          _ReminderTile(
            reminder: reminder,
            exact: _exactAllowed != false,
            onEdit: () => _openEditor(reminder),
          ),
        ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text("Add reminder"),
          onTap: () => _openEditor(),
        ),
      ],
    );
  }
}

/// Where there is no clock to schedule against.
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader("Reminders"),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "This operating system does not support reminders: nothing here "
              "can be woken to run one while the app is closed.",
            ),
          ),
        ],
      );
}

/// One reminder as a row: what and when, with the switch that arms it.
class _ReminderTile extends ConsumerWidget {
  const _ReminderTile({
    required this.reminder,
    required this.exact,
    required this.onEdit,
  });

  final Reminder reminder;
  final bool exact;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final project = projectOrDefault(reminder.project, named);
    final summary = [
      if (reminder.enabled && reminder.nextFireAt != null)
        "${exact ? "" : "approx. "}${describeFire(reminder.nextFireAt!)}",
      if (reminder.repeat != ReminderRepeat.off) reminder.repeat.label,
      if (project != null) projectLabel(project),
    ].join(" · ");
    final subtitle = summary.isNotEmpty
        ? summary
        : reminder.lastFiredAt == null
            ? "Never fired"
            : "Last fired ${shortDate(reminder.lastFiredAt!)}";

    return ListTile(
      title: Text(reminder.name.isEmpty ? reminder.prompt : reminder.name),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Switch(
        value: reminder.enabled,
        onChanged: (enabled) =>
            ref.read(remindersProvider.notifier).setEnabled(reminder.id, enabled),
      ),
      onTap: onEdit,
    );
  }
}

/// The add/edit page, pushed over whatever listed the reminders. The prompt is
/// the middle of the page and grows with it: it is what the reminder is.
class ReminderEditorPage extends ConsumerStatefulWidget {
  const ReminderEditorPage({super.key, this.reminder});

  final Reminder? reminder;

  @override
  ConsumerState<ReminderEditorPage> createState() => _ReminderEditorPageState();
}

class _ReminderEditorPageState extends ConsumerState<ReminderEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late DateTime _at;
  late ReminderRepeat _repeat;
  late String? _project;
  late bool _temporary;

  @override
  void initState() {
    super.initState();
    final reminder = widget.reminder;
    _name = TextEditingController(text: reminder?.name ?? "");
    _prompt = TextEditingController(text: reminder?.prompt ?? "");
    _at = reminder?.at ?? _defaultAt();
    _repeat = reminder?.repeat ?? ReminderRepeat.off;
    _project = reminder?.project;
    _temporary = reminder?.temporary ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  /// A new reminder defaults to the next whole hour, so picking a time is one
  /// spin rather than starting from now-and-a-few-minutes.
  static DateTime _defaultAt() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  @override
  Widget build(BuildContext context) {
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final effectiveTtl =
        ref.watch(projectSettingsProvider(_project)).tempChatTtl ??
            ref.watch(appSettingsProvider).tempChatTtl;
    final isNew = widget.reminder == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? "New reminder" : "Edit reminder"),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Delete reminder",
              onPressed: _delete,
            ),
          TextButton(onPressed: _save, child: const Text("Save")),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: "Name"),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _pickDate,
                  child: Text(shortDate(_at)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _pickTime,
                  child: Text(timeOfDay(_at)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TabIndents(
                controller: _prompt,
                child: TextField(
                  controller: _prompt,
                  expands: true,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: "What should the agent do?",
                    alignLabelWithHint: true,
                    labelText: "Prompt",
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              children: [
                LabelledField(
                  label: "Repeat",
                  child: DropdownButtonFormField<ReminderRepeat>(
                    initialValue: _repeat,
                    isExpanded: true,
                    items: [
                      for (final repeat in ReminderRepeat.values)
                        DropdownMenuItem(value: repeat, child: Text(repeat.label)),
                    ],
                    onChanged: (repeat) =>
                        setState(() => _repeat = repeat ?? ReminderRepeat.off),
                  ),
                ),
                SwitchListTile(
                  title: const Text("Temporary chat"),
                  subtitle: Text(effectiveTtl == TempChatTtl.off
                      ? "The chat is kept"
                      : "The chat expires after "
                          "${tempChatTtlLabels[effectiveTtl] ?? effectiveTtl.name}"),
                  value: _temporary,
                  onChanged: (value) => setState(() => _temporary = value),
                ),
                LabelledField(
                  label: "Project",
                  child: DropdownButtonFormField<String?>(
                    initialValue: projectOrDefault(
                        _project, named),
                    isExpanded: true,
                    items: [
                      for (final project in everyProject(named))
                        DropdownMenuItem(
                            value: project, child: Text(projectLabel(project))),
                    ],
                    onChanged: (project) => setState(() => _project = project),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _at = DateTime(picked.year, picked.month, picked.day, _at.hour, _at.minute);
    });
  }

  Future<void> _pickTime() async {
    final picked =
        await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (picked == null || !mounted) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, picked.hour, picked.minute);
    });
  }

  Future<void> _save() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Write the prompt first.")));
      return;
    }
    // A one-shot set in the past would be born already fired; a repeating one
    // in the past is fine, since it has occurrences ahead of it.
    final isNew = widget.reminder == null;
    if (isNew && !_at.isAfter(DateTime.now()) && _repeat == ReminderRepeat.off) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Pick a time in the future.")));
      return;
    }
    // Recomputed on save rather than carried over: an edit into the past means
    // the next occurrence after now, never a fire in the past.
    final reminder = (widget.reminder ?? _newReminder(prompt))
        .copyWith(
          name: _name.text.trim(),
          prompt: prompt,
          at: _at,
          repeat: _repeat,
          project: _project,
          temporary: _temporary,
          enabled: true,
          clearNextFireAt: true,
        )
        .copyWith(nextFireAt: Reminder.occurrenceAfter(_repeat, _at, DateTime.now()));
    final notifier = ref.read(remindersProvider.notifier);
    if (isNew) {
      await notifier.add(reminder);
    } else {
      await notifier.replace(reminder);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Reminder _newReminder(String prompt) => Reminder(
        id: const Uuid().v4(),
        name: "",
        prompt: prompt,
        at: _at,
        repeat: _repeat,
        project: _project,
        temporary: _temporary,
      );

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: "Delete reminder",
      message: "Delete this reminder?",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(remindersProvider.notifier).remove(widget.reminder!.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }
}

/// When the next fire is, in as few words as say it: today and tomorrow by
/// name, then weekday and date.
String describeFire(DateTime at) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final difference = day.difference(today).inDays;
  final when = timeOfDay(at);
  if (difference == 0) return "Today $when";
  if (difference == 1) return "Tomorrow $when";
  return "${shortDate(at)} $when";
}

const _weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const _months = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

String shortDate(DateTime at) =>
    "${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}";

String timeOfDay(DateTime at) {
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, "0");
  return "$hour:$minute ${at.hour < 12 ? "AM" : "PM"}";
}
