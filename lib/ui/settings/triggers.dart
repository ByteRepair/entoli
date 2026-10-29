import "dart:async";

import "package:clock/clock.dart";
import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/date_words.dart" show describeFire, shortDate, timeOfDay;
import "../../domain/models.dart" show CompletionKind;
import "../../domain/project.dart";
import "../../domain/trigger.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../providers.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/reply_style.dart";
import "../widgets/completion_field.dart";
import "../widgets/dialogs.dart" show confirm, promptForText;
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "../widgets/temp_chat_ttl_field.dart";

/// The Triggers category: a prompt a schedule, a countdown or a file change
/// sends. Android, macOS, iOS and Linux all have a platform half: on Android
/// and macOS the system clock fires a schedule with the app closed
/// (AlarmManager; launchd), on iOS it delivers the moment a notification the
/// turn is run by catching up at the next open, on Linux the session bus's
/// notifications announce what one did — scheduling there still rides the
/// app's own timer. Where the port is unavailable the category is not listed
/// (`SettingsCategory.offered`).
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
    final summary = [
      if (trigger.enabled && trigger.nextFireAt != null)
        "${exact ? "" : "approx. "}${describeFire(trigger.nextFireAt!, clock.now())}",
      if (trigger.enabled && trigger.nextFireAt == null)
        if (trigger.source case FileSource(:final paths))
          "File: ${paths.join(", ")}",
      if (trigger.source is ScheduleSource)
        (trigger.source as ScheduleSource).repeat.label,
      if (trigger.member != null) "@${trigger.member}",
      if (project != null) projectLabel(project),
      if (trigger.byAgent) "Set by the agent",
    ].join(" · ");
    final subtitle = summary.isNotEmpty
        ? summary
        : trigger.lastFiredAt == null
            ? "Never fired"
            : "Last fired ${shortDate(trigger.lastFiredAt!)}";

    return ListTile(
      title: Text(trigger.label),
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

  /// The member the fire is addressed to, sigil off — edited on the editor's
  /// own row, held through kind switches like the sources are.
  late String? _member;
  late TempChatTtl? _tempChatTtl;
  late final Clock _clock;

  @override
  void initState() {
    super.initState();
    final trigger = widget.trigger;
    _clock = ref.read(clockProvider);
    _name = TextEditingController(text: trigger?.name ?? "");
    _prompt = trigger?.prompt ?? "";
    _source = trigger?.source ?? ScheduleSource(at: _defaultAt());
    _project = trigger?.project;
    _member = trigger?.member;
    _tempChatTtl = trigger?.tempChatTtl;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// A new schedule defaults to the next whole hour, so picking a time is one
  /// spin rather than starting from now-and-a-few-minutes.
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
          // The agent's trigger is the switch and the delete: anything else
          // saved here would rewrite what its conversation armed (source,
          // anchor, re-enable) from a page whose prompt it refuses to touch.
          if (!registered) TextButton(onPressed: _save, child: const Text("Save")),
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
              // Nothing is saved from this page while it is the agent's, so
              // nothing here looks editable either — the rows below follow
              // the same gate.
              onSelectionChanged: registered
                  ? null
                  : (selection) => setState(() {
                      _source = _sourceFor(selection.first);
                    }),
            ),
          ),
          ..._sourceFields(editable: !registered),
          _memberField(!registered),
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

  /// The member row, both targets one shape: a chatless fire makes its new
  /// chat with the member as the first speaker, a same-chat one queues on
  /// the member's FIFO — the same dropdown either way, since addressing is
  /// not a property of where the fire lands. A project's own members over
  /// the inherited ones, the library's tier walk. A stored member the
  /// library has since lost stays named, with the line saying what fires
  /// will do about it — clearing it silently would rewrite what was armed.
  Widget _memberField(bool editable) {
    final members = ref
        .watch(promptLibraryProvider(_project))
        .entries(CompletionKind.agent)
        .map((e) => e.name)
        .toList();
    final vanished = _member != null && !members.contains(_member);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabelledField(
          label: "Address to",
          child: DropdownButtonFormField<String?>(
            initialValue: _member,
            isExpanded: true,
            decoration: const InputDecoration(hintText: "The whole room"),
            items: [
              const DropdownMenuItem(value: null, child: Text("The whole room")),
              if (vanished)
                DropdownMenuItem(
                    value: _member, child: Text("@$_member (deleted)")),
              for (final member in members)
                DropdownMenuItem(value: member, child: Text("@$member")),
            ],
            // A vanished member can be kept as it is or exchanged, not
            // re-picked from a list that no longer names it — and where the
            // trigger is the agent's, nothing here may rewrite what it
            // registered.
            onChanged:
                editable ? (member) => setState(() => _member = member) : null,
          ),
        ),
        if (vanished)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              "This agent no longer exists; a fire will reach the whole room.",
              style: TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// What each kind's rows hold while the other kind is showing — one slot
  /// per kind, filled as its rows are edited. Written when a kind is left
  /// as well as when its own row changes, so switching to Countdown and
  /// back keeps what was typed rather than reading the trigger's original
  /// once and losing every edit in between.
  final _kept = <_SourceKind, TriggerSource>{};

  /// A source of the kind just picked: this kind's kept state when there is
  /// any, else what the trigger was saved with, else the kind's default.
  TriggerSource _sourceFor(_SourceKind kind) {
    _kept[_kindOf(_source)] ??= _source;
    return _kept[kind] ?? _keptFor(kind);
  }

  TriggerSource _keptFor(_SourceKind kind) {
    final saved = widget.trigger?.source;
    if (saved != null && _kindOf(saved) == kind) return saved;
    return switch (kind) {
      _SourceKind.schedule => ScheduleSource(at: _defaultAt()),
      _SourceKind.timer => TimerSource(
          duration: const Duration(minutes: 30), registeredAt: _clock.now()),
      _SourceKind.file => const FileSource(paths: []),
    };
  }

  /// The rows the kind picked needs: date and time, countdown minutes, or
  /// paths and their events. Read-only where the trigger is the agent's —
  /// the switch and the delete are what is left.
  List<Widget> _sourceFields({required bool editable}) => switch (_kindOf(_source)) {
        _SourceKind.schedule => [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: editable ? _pickDate : null,
                      icon: const Icon(Icons.event_outlined, size: 18),
                      label: Text(shortDate((_source as ScheduleSource).at)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: editable ? _pickTime : null,
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
                onChanged: editable
                    ? (repeat) => setState(() => _source =
                        ScheduleSource(
                            at: (_source as ScheduleSource).at,
                            repeat: repeat ?? ScheduleRepeat.off))
                    : null,
              ),
            ),
          ],
        _SourceKind.timer => [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined, size: 18),
                title: Text((_source as TimerSource).describe()),
                subtitle: const Text("Countdown from being registered"),
                onTap: editable ? _pickDuration : null,
              ),
            ),
          ],
        _SourceKind.file => [
            _FileSourceField(
              source: _source as FileSource,
              onChanged:
                  editable ? (source) => setState(() => _source = source) : null,
            ),
          ],
      };

  Future<void> _pickDuration() async {
    final current = (_source as TimerSource).duration;
    final minutes = await promptForText(
      context,
      title: "Countdown",
      initial: "${current.inMinutes}",
      confirmLabel: "Set",
      hint: "Minutes",
    );
    if (!mounted || minutes == null) return;
    final parsed = int.tryParse(minutes);
    if (parsed == null || parsed <= 0) return;
    setState(() => _source = TimerSource(
        duration: Duration(minutes: parsed), registeredAt: _clock.now()));
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
    final isNew = widget.trigger == null;
    final prompt = _prompt.trim();
    // A one-shot set in the past would be born already fired; a repeating one
    // in the past is fine, since it has occurrences ahead of it.
    final refusal = prompt.isEmpty
        ? "Write the prompt first."
        : switch (_source) {
            ScheduleSource(:final at, repeat: ScheduleRepeat.off)
                when isNew && !at.isAfter(_clock.now()) =>
              "Pick a time in the future.",
            FileSource(:final paths) when paths.isEmpty =>
              "Name at least one path to watch.",
            FileSource(:final events) when events.isEmpty =>
              "Pick what a change is — with nothing picked it would never fire.",
            _ => null,
          };
    if (refusal != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(refusal)));
      return;
    }
    if (_source case TimerSource(:final duration)) {
      // A countdown fires once from being set; re-saving re-sets it.
      _source = TimerSource(duration: duration, registeredAt: _clock.now());
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
          member: _member,
          clearMember: _member == null,
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
        member: _member,
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
}

enum _SourceKind { schedule, timer, file }

/// The file source's rows: one path at a time and the kinds of change to fire
/// on. The paths are typed the way the file tools read them — workspace-relative,
/// or `project:`-prefixed — since the watch resolves them exactly there.
class _FileSourceField extends StatefulWidget {
  const _FileSourceField({required this.source, required this.onChanged});

  final FileSource source;

  /// Null where the row is read-only — an agent-registered trigger's.
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
                onPressed:
                    widget.onChanged == null ? null : () => _add(_path.text),
              ),
            ],
          ),
        ),
        for (final path in source.paths)
          ListTile(
            dense: true,
            leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
            title: Text(path),
            trailing: widget.onChanged == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Remove path",
                    onPressed: () => _emit(
                        paths: [...source.paths]..remove(path)),
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
                  onSelected: widget.onChanged == null
                      ? null
                      : (on) => _emit(
                          events: on
                              ? {...source.events, event}
                              : ({...source.events}..remove(event))),
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
    _emit(paths: [...widget.source.paths, path]);
    _path.clear();
  }

  void _emit({List<String>? paths, Set<FileEvent>? events}) {
    final source = widget.source;
    widget.onChanged?.call(FileSource(
        paths: paths ?? source.paths,
        events: events ?? source.events,
        cooldown: source.cooldown));
  }
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
