import "dart:async";

import "package:clock/clock.dart";
import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/project.dart";
import "../../domain/trigger.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart" show confirm;
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/temp_chat_ttl_field.dart";

/// The Triggers category: a prompt a schedule, a countdown or a file change
/// sends. Android and Linux both have a platform half: on Android the system
/// clock fires a schedule with the app closed, on Linux the session bus's
/// notifications announce what one did — scheduling there still rides the
/// app's own timer, so where the port is unavailable the page says so and
/// offers nothing, the way a row for a missing device would.
class TriggersSection extends ConsumerStatefulWidget {
  const TriggersSection({super.key});

  @override
  ConsumerState<TriggersSection> createState() => _TriggersSectionState();
}

class _TriggersSectionState extends ConsumerState<TriggersSection> {
  bool? _notificationsAllowed;
  bool? _exactAllowed;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // The rows lead to the system settings, where the answers can change while
    // the app is behind, so the page re-asks every time it comes back.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_loadPermissions()));
    unawaited(_loadPermissions());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
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

  Future<void> _openEditor([Trigger? trigger]) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TriggerEditorPage(trigger: trigger)),
      );

  @override
  Widget build(BuildContext context) {
    final alarms = ref.watch(reminderAlarmsProvider);
    if (!alarms.available) return const _Unavailable();
    final triggers = ref.watch(triggersProvider);

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
        if (_notificationsAllowed == false)
          ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text("Notifications are off"),
            subtitle: const Text("Allow them to see when a trigger finishes."),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                unawaited(ref.read(reminderAlarmsProvider).requestNotifications()),
          ),
        if (_exactAllowed == false)
          ListTile(
            leading: const Icon(Icons.alarm_off_outlined),
            title: const Text("Exact times are not granted"),
            subtitle: const Text(
              "Without them a schedule may fire minutes late, and its turn can "
              "be cut short while the app is closed.",
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => unawaited(ref.read(reminderAlarmsProvider).requestExact()),
          ),
        for (final trigger in triggers)
          _TriggerTile(
            trigger: trigger,
            exact: _exactAllowed != false,
            onEdit: () => _openEditor(trigger),
          ),
        ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text("Add trigger"),
          onTap: () => _openEditor(),
        ),
      ],
    );
  }
}

/// Where there is no clock to schedule against and no notifications to post
/// through — nothing of what a trigger does can be heard.
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader("Triggers"),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              "This operating system does not support triggers: nothing here "
              "can notify what one did, and nothing can wake the app to run "
              "one while it is closed.",
            ),
          ),
        ],
      );
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
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final project = projectOrDefault(trigger.project, named);
    final clock = ref.watch(clockProvider);
    final source = _sourceLine(trigger.source, exact: exact, clock: clock);
    final summary = [
      if (trigger.enabled && trigger.nextFireAt != null)
        "${exact ? "" : "approx. "}${describeFire(trigger.nextFireAt!, clock.now())}",
      if (trigger.enabled && trigger.nextFireAt == null && trigger.source is FileSource)
        source,
      if (trigger.source is ScheduleSource)
        (trigger.source as ScheduleSource).repeat.label,
      if (project != null) projectLabel(project),
      if (trigger.byAgent) "Set by the agent",
    ].join(" · ");
    final subtitle = summary.isNotEmpty
        ? summary
        : trigger.lastFiredAt == null
            ? "Never fired"
            : "Last fired ${shortDate(trigger.lastFiredAt!)}";

    return ListTile(
      title: Text(trigger.name.isEmpty ? trigger.prompt : trigger.name),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Switch(
        value: trigger.enabled,
        onChanged: (enabled) =>
            ref.read(triggersProvider.notifier).setEnabled(trigger.id, enabled),
      ),
      onTap: onEdit,
    );
  }
}

/// What a source is, one line, for the row and the editor: the kind's own
/// description, the moment where it is on the clock.
String _sourceLine(TriggerSource source,
    {required bool exact, required Clock clock}) {
  final approximate = exact ? "" : "approx. ";
  final line = switch (source) {
    ScheduleSource(:final at, :final repeat) => repeat == ScheduleRepeat.off
        ? approximate + describeFire(at, clock.now())
        : repeat.label,
    TimerSource() => source.describe(),
    FileSource(:final paths) => "File: ${paths.join(", ")}",
  };
  return line;
}

/// The add/edit page, pushed over whatever listed the triggers. What the
/// trigger is stays the middle of the page, but as the message it will send
/// rather than as a box to type in: writing it is [TriggerPromptPage]'s, and
/// this shows what was written the way the chat will.
///
/// A trigger the agent registered through the tools opens as its own kind of
/// page: the prompt is the conversation's, and the only things to change are
/// the switch and the delete.
class TriggerEditorPage extends ConsumerStatefulWidget {
  const TriggerEditorPage({super.key, this.trigger});

  final Trigger? trigger;

  @override
  ConsumerState<TriggerEditorPage> createState() => _TriggerEditorPageState();
}

class _TriggerEditorPageState extends ConsumerState<TriggerEditorPage> {
  late final TextEditingController _name;

  /// Held as text rather than in a controller: nothing on this page types into
  /// it, and the page that does hands back what it ended up with.
  late String _prompt;
  late TriggerSource _source;
  late String? _project;
  late TempChatTtl? _tempChatTtl;
  late final Clock _clock;

  @override
  void initState() {
    super.initState();
    final trigger = widget.trigger;
    _clock = ref.read(clockProvider);
    _name = TextEditingController(text: trigger?.name ?? "");
    _prompt = trigger?.prompt ?? "";
    _source = trigger?.source ?? _defaultSource();
    _project = trigger?.project;
    _tempChatTtl = trigger?.tempChatTtl;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// A new schedule defaults to the next whole hour, so picking a time is one
  /// spin rather than starting from now-and-a-few-minutes.
  TriggerSource _defaultSource() => ScheduleSource(at: _defaultAt());

  DateTime _defaultAt() {
    final now = _clock.now();
    return DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  @override
  Widget build(BuildContext context) {
    final named = ref.watch(projectListProvider).value ?? const <String>[];
    final isNew = widget.trigger == null;
    final registered = widget.trigger?.byAgent ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? "New trigger" : "Edit trigger"),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "Delete trigger",
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
          LabelledField(
            label: "When",
            child: SegmentedButton<_SourceKind>(
              segments: const [
                ButtonSegment(value: _SourceKind.schedule, label: Text("Time")),
                ButtonSegment(value: _SourceKind.timer, label: Text("Countdown")),
                ButtonSegment(value: _SourceKind.file, label: Text("Files")),
              ],
              selected: {_kindOf(_source)},
              onSelectionChanged: (selection) => setState(() {
                _source = _sourceFor(selection.first);
              }),
            ),
          ),
          ..._sourceFields(),
          _PromptPreview(prompt: _prompt, onEdit: _editPrompt, editable: !registered),
          const Divider(height: 1),
          if (!registered) ...[
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
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                "This trigger was set by the agent in its chat. Switch it off "
                "or delete it here; the prompt is the conversation's.",
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }

  _SourceKind _kindOf(TriggerSource source) => switch (source) {
        ScheduleSource() => _SourceKind.schedule,
        TimerSource() => _SourceKind.timer,
        FileSource() => _SourceKind.file,
      };

  /// A fresh source of the kind just picked, so switching kinds does not
  /// carry one kind's data into another's row.
  TriggerSource _sourceFor(_SourceKind kind) {
    final current = widget.trigger?.source;
    return switch (kind) {
      _SourceKind.schedule => current is ScheduleSource
          ? current
          : ScheduleSource(at: _defaultAt()),
      _SourceKind.timer => current is TimerSource
          ? current
          : TimerSource(
              duration: const Duration(minutes: 30),
              registeredAt: _clock.now()),
      _SourceKind.file => current is FileSource ? current : const FileSource(paths: []),
    };
  }

  /// The rows the kind picked needs: date and time, countdown minutes, or
  /// paths and their events.
  List<Widget> _sourceFields() => switch (_kindOf(_source)) {
        _SourceKind.schedule => [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_outlined, size: 18),
                      label: Text(shortDate((_source as ScheduleSource).at)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule_outlined, size: 18),
                      label: Text(timeOfDay((_source as ScheduleSource).at)),
                    ),
                  ),
                ],
              ),
            ),
            LabelledField(
              label: "Repeat",
              child: DropdownButtonFormField<ScheduleRepeat>(
                initialValue: (_source as ScheduleSource).repeat,
                isExpanded: true,
                items: [
                  for (final repeat in ScheduleRepeat.values)
                    DropdownMenuItem(value: repeat, child: Text(repeat.label)),
                ],
                onChanged: (repeat) => setState(() => _source =
                    ScheduleSource(
                        at: (_source as ScheduleSource).at,
                        repeat: repeat ?? ScheduleRepeat.off)),
              ),
            ),
          ],
        _SourceKind.timer => [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined, size: 18),
                title: Text(_TriggerEditorPageState.timerWords(
                    (_source as TimerSource).duration)),
                subtitle: const Text("Countdown from being registered"),
                onTap: _pickDuration,
              ),
            ),
          ],
        _SourceKind.file => [
            FileSourceField(
              source: _source as FileSource,
              onChanged: (source) => setState(() => _source = source),
            ),
          ],
      };

  Future<void> _pickDuration() async {
    final current = (_source as TimerSource).duration;
    final minutes = await showInputDialog(
      context,
      title: "Countdown",
      label: "Minutes",
      initial: (current.inMinutes).toString(),
    );
    if (minutes == null) return;
    final parsed = int.tryParse(minutes);
    if (parsed == null || parsed <= 0) return;
    setState(() => _source = TimerSource(
        duration: Duration(minutes: parsed), registeredAt: _clock.now()));
    if (!mounted) return;
  }

  Future<void> _editPrompt() async {
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(
          builder: (_) => TriggerPromptPage(prompt: _prompt, project: _project)),
    );
    if (edited == null || !mounted) return;
    setState(() => _prompt = edited);
  }

  Future<void> _pickDate() async {
    final now = _clock.now();
    final at = (_source as ScheduleSource).at;
    final picked = await showDatePicker(
      context: context,
      initialDate: at,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _source = ScheduleSource(
          at: DateTime(picked.year, picked.month, picked.day, at.hour, at.minute),
          repeat: (_source as ScheduleSource).repeat);
    });
  }

  Future<void> _pickTime() async {
    final at = (_source as ScheduleSource).at;
    final picked =
        await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(at));
    if (picked == null || !mounted) return;
    setState(() {
      _source = ScheduleSource(
          at: DateTime(at.year, at.month, at.day, picked.hour, picked.minute),
          repeat: (_source as ScheduleSource).repeat);
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
    final isNew = widget.trigger == null;
    // A one-shot set in the past would be born already fired; a repeating one
    // in the past is fine, since it has occurrences ahead of it.
    final schedule = _source is ScheduleSource ? _source as ScheduleSource : null;
    final timer = _source is TimerSource ? _source as TimerSource : null;
    if (schedule != null &&
        isNew &&
        !schedule.at.isAfter(_clock.now()) &&
        schedule.repeat == ScheduleRepeat.off) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Pick a time in the future.")));
      return;
    }
    if (timer != null) {
      // A countdown fires once from being set; re-saving re-sets it.
      _source = TimerSource(
          duration: timer.duration, registeredAt: _clock.now());
    }
    if (_source is FileSource && (_source as FileSource).paths.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text("Name at least one path to watch.")));
      return;
    }
    // Recomputed on save rather than carried over: an edit into the past means
    // the next occurrence after now, never a fire in the past.
    final next = _source.nextAfter(_clock.now());
    final trigger = (widget.trigger ?? _newTrigger(prompt))
        .copyWith(
          name: _name.text.trim(),
          prompt: prompt,
          source: _source,
          project: _project,
          tempChatTtl: _tempChatTtl,
          clearTempChatTtl: _tempChatTtl == null,
          enabled: true,
          clearNextFireAt: true,
        )
        .copyWith(nextFireAt: next);
    final notifier = ref.read(triggersProvider.notifier);
    if (isNew) {
      await notifier.add(trigger);
    } else {
      await notifier.replace(trigger);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Trigger _newTrigger(String prompt) => Trigger(
        id: const Uuid().v4(),
        name: "",
        prompt: prompt,
        source: _source,
        project: _project,
        tempChatTtl: _tempChatTtl,
      );

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: "Delete trigger",
      message: "Delete this trigger?",
      confirmLabel: "Delete",
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ref.read(triggersProvider.notifier).remove(widget.trigger!.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// The countdown in the editor's own words, from the tool's too — one
  /// wording of a duration, wherever one is described.
  static String timerWords(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes < 60) return "In $minutes minutes";
    final hours = duration.inHours;
    final leftover = minutes % 60;
    return leftover == 0 ? "In $hours hours" : "In $hours h $leftover min";
  }
}

enum _SourceKind { schedule, timer, file }

/// The file source's rows: one path at a time, the kinds of change to fire
/// on, and how long a trigger stays quiet after it has fired. The paths are
/// typed the way the file tools read them — workspace-relative, or
/// `project:`-prefixed — since the watch resolves them exactly there.
class FileSourceField extends ConsumerStatefulWidget {
  const FileSourceField({super.key, required this.source, required this.onChanged});

  final FileSource source;
  final void Function(FileSource) onChanged;

  @override
  ConsumerState<FileSourceField> createState() => _FileSourceFieldState();
}

class _FileSourceFieldState extends ConsumerState<FileSourceField> {
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _path,
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
                onPressed: () => _add(_path.text),
              ),
            ],
          ),
        ),
        for (final path in source.paths)
          ListTile(
            dense: true,
            leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
            title: Text(path),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              tooltip: "Remove path",
              onPressed: () => widget.onChanged(FileSource(
                  paths: [
                    for (final p in source.paths)
                      if (p != path) p,
                  ],
                  events: source.events,
                  cooldown: source.cooldown)),
            ),
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
                  onSelected: (on) => widget.onChanged(FileSource(
                      paths: source.paths,
                      events: on
                          ? {...source.events, event}
                          : source.events.where((e) => e != event).toSet(),
                      cooldown: source.cooldown)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _add(String text) {
    final path = text.trim();
    if (path.isEmpty || widget.source.paths.contains(path)) return;
    widget.onChanged(FileSource(
        paths: [...widget.source.paths, path],
        events: widget.source.events,
        cooldown: widget.source.cooldown));
    _path.clear();
  }
}

/// A one-line text dialog, for the countdown's minutes. Nothing else on this
/// page wants one, which is why it lives this close to its one caller.
Future<String?> showInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? "");
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onSubmitted: Navigator.of(context).pop,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
        TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text("Set")),
      ],
    ),
  );
  controller.dispose();
  return value;
}

/// The prompt as the chat will render it, over the button that changes it.
/// Formatted rather than raw: what a trigger sends is a message, and a
/// message is read as markdown everywhere else in the app — so a prompt with a
/// list in it is checked here rather than in the chat it eventually runs in.
class _PromptPreview extends StatelessWidget {
  const _PromptPreview({required this.prompt, required this.onEdit, this.editable = true});

  final String prompt;
  final VoidCallback onEdit;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LabelledField(
      label: "Prompt",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: editable ? onEdit : null,
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
          if (editable) ...[
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
        ],
      ),
    );
  }
}

/// The prompt on a page of its own: the box is the page, and it is the
/// composer's own field, so `/commands` and `@agents` complete here the way
/// they do in a chat — a trigger's prompt is dispatched through the same
/// library, and being offered them anywhere else and not here was the tell.
///
/// Pops the new prompt, or nothing where it was discarded.
class TriggerPromptPage extends StatefulWidget {
  const TriggerPromptPage({super.key, required this.prompt, this.project});

  final String prompt;

  /// The project whose library the `/` and `@` menus offer, so a trigger's
  /// prompt is composed against the same set the chat it makes will be. Null
  /// is the default project, the way it is everywhere a project is named.
  final String? project;

  @override
  State<TriggerPromptPage> createState() => _TriggerPromptPageState();
}

class _TriggerPromptPageState extends State<TriggerPromptPage> {
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
            project: widget.project,
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
String describeFire(DateTime at, DateTime now) {
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