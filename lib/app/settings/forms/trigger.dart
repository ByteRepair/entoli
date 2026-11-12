import "package:uuid/uuid.dart";

import "../../../domain/temp_chat_ttl.dart";
import "../../../domain/trigger.dart";
import "../controller.dart";

/// Why [source] with [prompt] cannot be saved, or null where it can. A
/// one-shot set in the past would be born already fired; a repeating one in
/// the past is fine, since it has occurrences ahead of it.
String? triggerRefusal(
  TriggerSource source,
  String prompt, {
  required bool isNew,
  required DateTime now,
}) => prompt.trim().isEmpty
    ? "Write the prompt first."
    : switch (source) {
        ScheduleSource(:final at, repeat: ScheduleRepeat.off)
            when isNew && !at.isAfter(now) =>
          "Pick a time in the future.",
        FileSource(:final paths) when paths.isEmpty =>
          "Name at least one path to watch.",
        FileSource(:final events) when events.isEmpty =>
          "Pick what a change is — with nothing picked it would never fire.",
        _ => null,
      };

/// [trigger] saved with what was edited: a countdown set again from [now],
/// the next fire worked out afresh — an edit into the past means the next
/// occurrence after now, never a fire in the past — and armed.
Trigger savedTrigger(
  Trigger? trigger, {
  required String name,
  required String prompt,
  required TriggerSource source,
  required String? project,
  required String? member,
  required TempChatTtl? tempChatTtl,
  required DateTime now,
}) {
  final set = switch (source) {
    TimerSource(:final duration) => TimerSource(
      duration: duration,
      registeredAt: now,
    ),
    _ => source,
  };
  final base =
      trigger ??
      Trigger(
        id: const Uuid().v4(),
        name: "",
        prompt: prompt,
        source: set,
        project: project,
        member: member,
        tempChatTtl: tempChatTtl,
      );
  return base
      .copyWith(
        name: name.trim(),
        prompt: prompt.trim(),
        source: set,
        project: project,
        member: member,
        clearMember: member == null,
        tempChatTtl: tempChatTtl,
        clearTempChatTtl: tempChatTtl == null,
        enabled: true,
        clearNextFireAt: true,
      )
      .copyWith(nextFireAt: set.nextAfter(now));
}

/// A trigger as a form every frontend can ask: what it is called, when it
/// fires — a time, a countdown, or files changing — who it is addressed to,
/// what it says, where its chat goes and how long that chat lives. One the
/// agent registered is shown and not changed: the switch and the delete on
/// its row are what is left.
class TriggerForm extends SettingForm<Trigger> {
  TriggerForm(
    this.trigger, {
    required this.now,
    required this.projects,
    required this.members,
    required this.inheritedTtl,
  });

  final Trigger? trigger;
  final DateTime now;

  /// Each project a trigger's chat can go to, by its key ("" is the default
  /// project) and label.
  final List<(String, String)> projects;

  /// The agents a fire can be addressed to in a project, by its key.
  final List<String> Function(String project) members;

  /// How long a chat in a project lives where the trigger says nothing: the
  /// Default its Temporary chat names.
  final TempChatTtl Function(String project) inheritedTtl;

  bool get _registered => trigger?.byAgent ?? false;

  /// A new schedule defaults to the next whole hour, so picking a time is one
  /// spin rather than starting from now and a few minutes.
  DateTime get _nextHour =>
      DateTime(now.year, now.month, now.day, now.hour + 1);

  @override
  String get title => trigger == null ? "New trigger" : "Edit trigger";

  @override
  bool get page => true;

  @override
  String get discard => "Throw away the edits to this trigger?";

  @override
  Map<String, String> get initial {
    final source = trigger?.source ?? ScheduleSource(at: _nextHour);
    return {
      "name": trigger?.name ?? "",
      "kind": switch (source) {
        ScheduleSource() => "schedule",
        TimerSource() => "timer",
        FileSource() => "file",
      },
      "at": (switch (source) {
        ScheduleSource(:final at) => at,
        _ => _nextHour,
      }).toIso8601String(),
      "repeat": switch (source) {
        ScheduleSource(:final repeat) => repeat.name,
        _ => ScheduleRepeat.off.name,
      },
      "minutes":
          "${switch (source) {
            TimerSource(:final duration) => duration.inMinutes,
            _ => 30,
          }}",
      "paths": switch (source) {
        FileSource(:final paths) => paths.join("\n"),
        _ => "",
      },
      "events": FormMulti.encode(
        (switch (source) {
          FileSource(:final events) => events,
          _ => const FileSource(paths: []).events,
        }).map((e) => e.name),
      ),
      "member": trigger?.member ?? "",
      "prompt": trigger?.prompt ?? "",
      "project": trigger?.project ?? "",
      "ttl": trigger?.tempChatTtl?.name ?? "",
    };
  }

  TriggerSource _source(Map<String, String> a) => switch (a["kind"]) {
    "timer" => TimerSource(
      duration: Duration(minutes: int.tryParse(a["minutes"]!) ?? 0),
      registeredAt: now,
    ),
    "file" => FileSource(
      paths: [
        for (final line in a["paths"]!.split("\n"))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      events: {
        for (final name in FormMulti.decode(a["events"]))
          ?FileEvent.values.asNameMap()[name],
      },
    ),
    _ => ScheduleSource(
      at: DateTime.tryParse(a["at"]!) ?? _nextHour,
      repeat:
          ScheduleRepeat.values.asNameMap()[a["repeat"]] ?? ScheduleRepeat.off,
    ),
  };

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final editable = !_registered;
    final project = a["project"]!;
    final names = members(project);
    final member = a["member"]!;
    final vanished = member.isNotEmpty && !names.contains(member);
    return [
      if (_registered)
        const FormNote(
          "This trigger was set by the agent in its chat. Switch it off "
          "or delete it from the list; the prompt is the conversation's.",
        ),
      FormText("name", "Name", enabled: editable),
      FormChoice(
        "kind",
        label: "When",
        segmented: true,
        enabled: editable,
        const [
          FormOption("schedule", "Time"),
          FormOption("timer", "Countdown"),
          FormOption("file", "Files"),
        ],
      ),
      ...switch (a["kind"]) {
        "timer" => [
          FormDuration(
            "minutes",
            "Countdown",
            helper: "From being saved.",
            enabled: editable,
          ),
        ],
        "file" => [
          FormText(
            "paths",
            "Paths",
            lines: 3,
            hint: "project:notes.md",
            helper:
                "One a line, as the file tools read them: in the chat's "
                "workspace, or project:-prefixed.",
            enabled: editable,
          ),
          FormMulti("events", "Fires when a file is", [
            for (final event in FileEvent.values)
              FormOption(event.name, event.label),
          ], enabled: editable),
        ],
        _ => [
          FormDate("at", "At", enabled: editable),
          FormChoice("repeat", label: "Repeat", enabled: editable, [
            for (final repeat in ScheduleRepeat.values)
              FormOption(repeat.name, repeat.label),
          ]),
        ],
      },
      FormChoice("member", label: "Address to", enabled: editable, [
        const FormOption("", "The whole room"),
        if (vanished)
          FormOption(
            member,
            "@$member (deleted)",
            help:
                "This agent no longer exists; a fire will reach the whole "
                "room.",
          ),
        for (final name in names) FormOption(name, "@$name"),
      ]),
      FormPrompt(
        "prompt",
        "Prompt",
        hint: "What should the agent do?",
        project: project.isEmpty ? null : project,
        enabled: editable,
      ),
      if (editable) ...[
        FormChoice("ttl", label: "Temporary chat", [
          FormOption("", "Default (${inheritedTtl(project).label})"),
          for (final ttl in TempChatTtl.values) FormOption(ttl.name, ttl.label),
        ]),
        FormChoice("project", label: "Project", [
          for (final (key, label) in projects) FormOption(key, label),
        ]),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) => _registered
      ? ""
      : triggerRefusal(
          _source(a),
          a["prompt"]!,
          isNew: trigger == null,
          now: now,
        );

  @override
  Trigger build(Map<String, String> a) => savedTrigger(
    trigger,
    name: a["name"]!,
    prompt: a["prompt"]!,
    source: _source(a),
    project: a["project"]!.isEmpty ? null : a["project"],
    member: a["member"]!.isEmpty ? null : a["member"],
    tempChatTtl: TempChatTtl.values.asNameMap()[a["ttl"]],
    now: now,
  );
}
