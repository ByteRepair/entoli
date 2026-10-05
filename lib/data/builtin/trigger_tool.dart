import "../../domain/trigger.dart";
import "llm/llm_client.dart";

/// The trigger tools. The registry they run against is in
/// `lib/domain/trigger_manager.dart`, after the plan tools' pattern.

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
            "When the trigger fires, the reason it fired is appended below "
            "this message as one parenthetical line — write the prompt so a "
            "sentence in that shape makes sense.",
      },
      "name": {
        "type": "string",
        "description": "Optional short name; shown in the Triggers settings.",
      },
      "member": {
        "type": "string",
        "description": "Optional member of this project's Omada room to "
            "address the fire to — the agent's name without the @. The fire "
            "is sent as a message naming them, so the room routes it onto "
            "their turn the way any mention does; in a project with Omada "
            "off it is plain prose. Must be a name this project holds; the "
            "registration is refused otherwise.",
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

/// One registration's shape, parsed — what the arguments spell, and nothing
/// anchored to a clock. The registry arms it (a timer against its own
/// registering moment), so no parse carries a fabricated moment and no
/// holder has to overwrite one. Null where the arguments do not spell a
/// registration — the caller rejects with [triggerSetProblem]'s words.
class TriggerDraft {
  const TriggerDraft({
    required this.source,
    required this.prompt,
    this.name = "",
    this.member,
  });

  final TriggerSource source;
  final String prompt;
  final String name;

  /// The member the fire is addressed to, sigil off. Null where the
  /// arguments named none; validation is the registry's, which holds the
  /// library.
  final String? member;
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
    member: args["member"] is String ? (args["member"] as String).trim() : null,
  );
}

TriggerSource? _scheduleSource(Map<String, dynamic> args) {
  final rawAt = args["at"];
  // `is` over `as`: the arguments are the model's writing, and a number where
  // the ISO string belongs is a bad argument to reject, not a TypeError to
  // fail the turn with.
  final at = rawAt is String ? DateTime.tryParse(rawAt) : null;
  if (at == null) return null;
  final rawRepeat = args["repeat"];
  final repeat = switch (rawRepeat is String? ? rawRepeat : null) {
    null || "off" => ScheduleRepeat.off,
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
  // The anchor is the registry's to set (its registering moment); the parse
  // spells the duration and nothing else — no fabricated moment to patch.
  return TimerSource(duration: Duration(seconds: seconds), registeredAt: _draftAnchor);
}

/// The parse's placeholder for a timer's anchor: the epoch, a moment no
/// registry keeps. `registeredAt` is required by the model's constructor; a
/// draft carries a duration alone, so this stands where nothing reads it —
/// the registry re-dates the source before anything is stored, and
/// `nextAfter` on a draft is never asked.
final _draftAnchor = DateTime.fromMillisecondsSinceEpoch(0);


TriggerSource? _fileSource(Map<String, dynamic> args) {
  final raw = args["paths"];
  if (raw is! List || raw.isEmpty) return null;
  final paths = [if (raw.every((p) => p is String)) ...raw.cast<String>()];
  if (paths.length != raw.length) return null;
  final eventNames = args["events"];
  final events = eventNames == null
      ? FileEvent.values.toSet()
      : (eventNames is List ? _eventsFrom(eventNames) : null);
  if (events == null) return null;
  final cooldown = args["cooldownSeconds"];
  return FileSource(
    paths: paths,
    events: events,
    cooldown: cooldown is int && cooldown > 0
        ? Duration(seconds: cooldown)
        : const Duration(seconds: 5),
  );
}

/// The names the model wrote as events, through the enum's own
/// [FileEvent.fromName] — one list of what an event is called. Null where
/// one is not a name, the call being malformed rather than partial.
Set<FileEvent>? _eventsFrom(List<dynamic> eventNames) {
  final events = <FileEvent>{};
  for (final name in eventNames) {
    // `is` rather than `as`: a non-string element is rejected with the rest of
    // the malformed call, and no cast error reaches the turn.
    if (name is! String) return null;
    try {
      events.add(FileEvent.fromName(name));
    } on ArgumentError {
      return null;
    }
  }
  return events;
}

/// What went wrong with a `trigger_set` call's arguments, worded for the
/// result the tool answers with.
String triggerSetProblem(String? source) =>
    'The $triggerSetName tool takes {"source": "schedule"|"timer"|"file", '
    '"prompt": "..."} — a schedule wants {"at": "<ISO 8601>"}, a timer '
    '{"seconds": <count>}, a file {"paths": ["..."]}; that argument was '
    "missing or malformed.${source == null ? "" : " (source: $source)"}";
