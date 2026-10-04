import "../../domain/trigger.dart";
import "llm/llm_client.dart";

/// The trigger tools. Named in `lib/domain/trigger_tools.dart` beside the
/// registry they run against, after the plan tools' pattern.

const triggerSetName = "trigger_set";
const triggerRemoveName = "trigger_remove";
const triggerListName = "trigger_list";

/// Register a trigger whose fire sends into this chat: a message this
/// conversation sends itself at a time, after a countdown, or when a file
/// changes. The prompt is worded for this conversation, since it is this
/// conversation that will read it.
const triggerSetTool = LlmTool(
  name: triggerSetName,
  description:
      "Set a trigger that sends a message into this chat later, so the "
      "work continues on its own. Sources: schedule (a wall-clock time, "
      "repeating or not), timer (a countdown from now), file (when paths "
      "change — fires only while the app runs). Use it to pick work "
      "back up after a wait, to follow up on a build, or to watch a file "
      "you have been asked about.",
  schema: {
    "type": "object",
    "properties": {
      "source": {
        "type": "string",
        "enum": ["schedule", "timer", "file"],
        "description": "What sets the trigger off.",
      },
      "prompt": {
        "type": "string",
        "description": "The message to send into this chat when it fires. "
            "Write it so the sentence '(set by trigger_set: <reason>)' "
            "below it makes sense — the reason says why the trigger fired.",
      },
      "name": {
        "type": "string",
        "description": "Optional short name; shown in the Triggers settings.",
      },
      "at": {
        "type": "string",
        "description": "schedule: the wall-clock time to fire at, ISO 8601 "
            "(with an offset, or local time where there is none).",
      },
      "repeat": {
        "type": "string",
        "enum": ["off", "hourly", "daily", "weekly", "monthly"],
        "description": "schedule: defaults to off — one fire.",
      },
      "seconds": {
        "type": "integer",
        "description": "timer: the countdown from now, in seconds.",
      },
      "paths": {
        "type": "array",
        "items": {"type": "string"},
        "description": "file: the paths to watch, the shapes the read tool "
            "takes (workspace-relative, project:-prefixed). Everything "
            "under a path is in its reach.",
      },
      "events": {
        "type": "array",
        "items": {
          "type": "string",
          "enum": ["create", "change", "delete", "move"],
        },
        "description": "file: which changes fire; every kind where not "
            "given. A build log wants change; a drop folder wants create.",
      },
      "cooldownSeconds": {
        "type": "integer",
        "description": "file: how long the trigger stays quiet after it "
            "fired, so a burst of writes is one turn. Default 5.",
      },
    },
    "required": ["source", "prompt"],
  },
);

/// Remove one of this chat's own triggers, by id as `trigger_list` speaks
/// it.
const triggerRemoveTool = LlmTool(
  name: triggerRemoveName,
  description:
      "Remove one of this chat's own triggers, by the id trigger_list "
      "answered. Only what this chat registered is removable here.",
  schema: {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The id trigger_list answered.",
      },
    },
    "required": ["id"],
  },
);

/// The triggers this chat registered.
const triggerListTool = LlmTool(
  name: triggerListName,
  description:
      "List the triggers this chat registered, with their ids and next "
      "fires. What may be removed named here.",
  schema: {"type": "object", "properties": {}},
);

/// The three, in the order the list offers them.
const triggerToolDefs = <LlmTool>[triggerSetTool, triggerRemoveTool, triggerListTool];

/// One registration, parsed — the shape alone; the registry takes it and
/// answers what it stored (id, chat target, the arming against now). Null
/// where the arguments do not spell one — the caller rejects with
/// [triggerSetProblem]'s words.
class TriggerDraft {
  const TriggerDraft({
    required this.source,
    required this.prompt,
    this.name = "",
  });

  final TriggerSource source;
  final String prompt;
  final String name;
}

TriggerDraft? triggerDraftFromArgs({required Map<String, dynamic> args}) {
  final prompt = args["prompt"];
  if (prompt is! String || prompt.trim().isEmpty) return null;
  final kind = args["source"];
  final source = switch (kind) {
    "schedule" => _scheduleSource(args),
    "timer" => _timerSource(args),
    "file" => _fileSource(args),
    _ => null,
  };
  if (source == null) return null;
  return TriggerDraft(
    source: source,
    prompt: prompt.trim(),
    name: args["name"] is String ? args["name"] as String : "",
  );
}

TriggerSource? _scheduleSource(Map<String, dynamic> args) {
  final at = DateTime.tryParse(args["at"] as String? ?? "");
  if (at == null) return null;
  final repeat = switch (args["repeat"] as String? ?? "off") {
    "off" => ScheduleRepeat.off,
    "hourly" => ScheduleRepeat.hourly,
    "daily" => ScheduleRepeat.daily,
    "weekly" => ScheduleRepeat.weekly,
    "monthly" => ScheduleRepeat.monthly,
    _ => null,
  };
  if (repeat == null) return null;
  return ScheduleSource(at: at, repeat: repeat);
}

TriggerSource? _timerSource(Map<String, dynamic> args) {
  final seconds = args["seconds"];
  if (seconds is! int || seconds <= 0) return null;
  return TimerSource(duration: Duration(seconds: seconds), registeredAt: DateTime(2026));
}

TriggerSource? _fileSource(Map<String, dynamic> args) {
  final raw = args["paths"];
  if (raw is! List || raw.isEmpty) return null;
  final paths = [if (raw.every((p) => p is String)) ...raw.cast<String>()];
  if (paths.length != raw.length) return null;
  final eventNames = args["events"];
  final events = eventNames == null
      ? FileEvent.values.toSet()
      : {
          for (final name in eventNames)
            switch (name as String?) {
              "create" => FileEvent.create,
              "change" => FileEvent.change,
              "delete" => FileEvent.delete,
              "move" => FileEvent.move,
              _ => throw ArgumentError("event"),
            },
        };
  final cooldown = args["cooldownSeconds"];
  return FileSource(
    paths: paths,
    events: events,
    cooldown: cooldown is int && cooldown > 0
        ? Duration(seconds: cooldown)
        : const Duration(seconds: 5),
  );
}

/// What went wrong with a `trigger_set` call's arguments, worded for the
/// result the tool answers with.
String triggerSetProblem(String? source) =>
    'The $triggerSetName tool takes {"source": "schedule"|"timer"|"file", '
    '"prompt": "..."} — a schedule wants {"at": "<ISO 8601>"}, a timer '
    '{"seconds": <count>}, a file {"paths": ["..."]}; that argument was '
    "missing or malformed.${source == null ? "" : " (source: $source)"}";

/// A moment in the tools' answers, in the wording the settings page's row
/// reads the same way: month and day first, then the time.
String describeMoment(DateTime at) => ScheduleSource(at: at).describeWhen;
