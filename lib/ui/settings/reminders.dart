import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/project.dart";
import "../../domain/reminder.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart" show confirm;
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/temp_chat_ttl_field.dart";

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
            subtitle: const Text(
              "Without them a reminder may fire minutes late, and its turn can "
              "be cut short while the app is closed.",
            ),
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

/// The add/edit page, pushed over whatever listed the reminders. What the
/// reminder is stays the middle of the page, but as the message it will send
/// rather than as a box to type in: writing it is [ReminderPromptPage]'s, and
/// this shows what was written the way the chat will.
class ReminderEditorPage extends ConsumerStatefulWidget {
  const ReminderEditorPage({super.key, this.reminder});

  final Reminder? reminder;

  @override
  ConsumerState<ReminderEditorPage> createState() => _ReminderEditorPageState();
}

class _ReminderEditorPageState extends ConsumerState<ReminderEditorPage> {
  late final TextEditingController _name;

  /// Held as text rather than in a controller: nothing on this page types into
  /// it, and the page that does hands back what it ended up with.
  late String _prompt;
  late DateTime _at;
  late ReminderRepeat _repeat;
  late String? _project;
  late TempChatTtl? _tempChatTtl;

  @override
  void initState() {
    super.initState();
    final reminder = widget.reminder;
    _name = TextEditingController(text: reminder?.name ?? "");
    _prompt = reminder?.prompt ?? "";
    _at = reminder?.at ?? _defaultAt();
    _repeat = reminder?.repeat ?? ReminderRepeat.off;
    _project = reminder?.project;
    _tempChatTtl = reminder?.tempChatTtl;
  }

  @override
  void dispose() {
    _name.dispose();
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
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: "Name"),
            ),
          ),
          // The second row: what a reminder is set for is a date and a time
          // together, and either on its own is half an answer.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(shortDate(_at)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule_outlined, size: 18),
                    label: Text(timeOfDay(_at)),
                  ),
                ),
              ],
            ),
          ),
          _PromptPreview(prompt: _prompt, onEdit: _editPrompt),
          const Divider(height: 1),
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
          TempChatTtlField(
            value: _tempChatTtl,
            onChanged: (ttl) => setState(() => _tempChatTtl = ttl),
            project: _project,
          ),
          LabelledField(
            label: "Project",
            child: DropdownButtonFormField<String?>(
              initialValue: projectOrDefault(_project, named),
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
    );
  }

  Future<void> _editPrompt() async {
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ReminderPromptPage(prompt: _prompt)),
    );
    if (edited == null || !mounted) return;
    setState(() => _prompt = edited);
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
    final prompt = _prompt.trim();
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
          tempChatTtl: _tempChatTtl,
          clearTempChatTtl: _tempChatTtl == null,
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
        tempChatTtl: _tempChatTtl,
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

/// The prompt as the chat will render it, over the button that changes it.
/// Formatted rather than raw: what a reminder sends is a message, and a
/// message is read as markdown everywhere else in the app — so a prompt with a
/// list in it is checked here rather than in the chat it eventually runs in.
class _PromptPreview extends StatelessWidget {
  const _PromptPreview({required this.prompt, required this.onEdit});

  final String prompt;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LabelledField(
      label: "Prompt",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: prompt.trim().isEmpty
                  ? Text(
                      "What should the agent do?",
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    )
                  : MarkdownBody(
                      data: prompt,
                      styleSheet: replyStyleSheet(theme),
                      builders: codeBlockBuilders,
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text("Edit prompt"),
            ),
          ),
        ],
      ),
    );
  }
}

/// The prompt on a page of its own: the box is the page, and it is the
/// composer's own field, so `/commands` and `@agents` complete here the way
/// they do in a chat — a reminder's prompt is dispatched through the same
/// library, and being offered them anywhere else and not here was the tell.
///
/// Pops the new prompt, or nothing where it was discarded.
class ReminderPromptPage extends StatefulWidget {
  const ReminderPromptPage({super.key, required this.prompt});

  final String prompt;

  @override
  State<ReminderPromptPage> createState() => _ReminderPromptPageState();
}

class _ReminderPromptPageState extends State<ReminderPromptPage> {
  final GlobalKey<CompletionFieldState> _field = GlobalKey();
  late final TextEditingController _controller =
      TextEditingController(text: widget.prompt);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _edited => _controller.text != widget.prompt;

  /// Discarding is the one way out that loses what was typed, so it asks —
  /// and the back key comes through here for the same reason.
  Future<void> _discard() async {
    if (_edited) {
      final ok = await confirm(
        context,
        title: "Discard changes",
        message: "Throw away the edits to this prompt?",
        confirmLabel: "Discard",
        destructive: true,
      );
      if (!ok) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Prompt"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: "Discard",
            onPressed: _discard,
          ),
          actions: [
            PopupMenuButton<VoidCallback>(
              icon: const Icon(Icons.add),
              tooltip: "Insert",
              onSelected: (action) => action(),
              itemBuilder: (context) => completionInsertItems(context, _field),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_controller.text),
              child: const Text("Save"),
            ),
          ],
        ),
        body: SafeArea(
          child: CompletionField(
            key: _field,
            controller: _controller,
            expands: true,
            maxLines: null,
            autofocus: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: "What should the agent do?",
              alignLabelWithHint: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            // The box is the page, so the menu goes under it — where the
            // composer's is, which is against the edge the field is on.
            layout: (menu, field) => Column(
              children: [
                Expanded(child: field),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: menu,
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
