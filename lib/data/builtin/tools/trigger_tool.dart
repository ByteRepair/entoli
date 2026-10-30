import "../../../domain/agent_backend.dart";
import "../../../domain/date_words.dart" show describeFire;
import "../../../domain/file_tools.dart" show outsideWorkspaces;
import "../../../domain/tool_arg.dart";
import "../../../domain/trigger.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

/// The trigger tools. The registry they run against is in
/// `lib/domain/trigger_manager.dart`, after the plan tools' pattern.

const triggerSetName = "trigger_set";
const triggerRemoveName = "trigger_remove";
const triggerListName = "trigger_list";

/// The trigger tools: what sends a message into this chat later. Only a
/// top-level turn is its own chat's, so only it may register, list or
/// remove; a sub-agent, whose fire would send into a chat it is not, is
/// offered none of them.
abstract class _TriggerTool extends AgentTool {
  _TriggerTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.triggers;

  @override
  bool get offered => offer.caps.trigger && !offer.oneShot;
}

const _setSchema = {
  "type": "object",
  "properties": {
    "source": {
      "type": "string",
      "enum": ["schedule", "timer", "file"],
      "description": "What sets the trigger off.",
    },
    "prompt": {
      "type": "string",
      "description":
          "The message to send into this chat when it fires. "
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
      "description":
          "Optional member of this project's Omada room to "
          "address the fire to — the agent's name without the @. The fire "
          "is sent as a message naming them, so the room routes it onto "
          "their turn the way any mention does; in a project with Omada "
          "off it is plain prose. Must be a name this project holds; the "
          "registration is refused otherwise.",
    },
    "at": {
      "type": "string",
      "description":
          "schedule: the wall-clock time to fire at, ISO 8601 "
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
      "description":
          "file: the paths to watch, the shapes the read tool "
          "takes (workspace-relative, project:-prefixed). Everything "
          "under a path is in its reach.",
    },
    "events": {
      "type": "array",
      "items": {
        "type": "string",
        "enum": ["create", "change", "delete", "move"],
      },
      "description":
          "file: which changes fire; every kind where not "
          "given. A build log wants change; a drop folder wants create.",
    },
    "cooldownSeconds": {
      "type": "integer",
      "description":
          "file: how long the trigger stays quiet after it "
          "fired, so a burst of writes is one turn. Default 5.",
    },
  },
  "required": ["source", "prompt"],
};

/// Register a trigger whose fire sends into this chat: a message this
/// conversation sends itself at a time, after a countdown, or when a file
/// changes. The prompt is worded for this conversation, since it is this
/// conversation that will read it, and the registration is watched the
/// moment the list lands.
class TriggerSetTool extends _TriggerTool {
  TriggerSetTool(super.offer);

  @override
  String get name => triggerSetName;

  @override
  String get runningLabel => "Setting a trigger";

  @override
  String get fragment =>
      "`$triggerSetName`/`$triggerListName`/"
      "`$triggerRemoveName` to set what sends a message into this chat later";

  @override
  String get description =>
      "Set a trigger that sends a message into this "
      "chat later, so the work continues on its own. Sources: schedule (a "
      "wall-clock time, repeating or not), timer (a countdown from now), file "
      "(when paths change — fires only while the app runs). Use it to pick "
      "work back up after a wait, to follow up on a build, or to watch a file "
      "you have been asked about.";

  @override
  Map<String, dynamic> get schema => _setSchema;

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = decodeArgs(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(call, triggerSetProblem(null));
      return;
    }
    final draft = triggerDraftFromArgs(args: args);
    if (draft == null) {
      yield* toolRejected(
        call,
        triggerSetProblem(stringArg(call.argumentsJson, "source")),
      );
      return;
    }
    // A file watch is never asked before it fires (and a fire's headless
    // turn runs approveMode never), so the outside paths the read tool
    // raises a banner over are refused here, where the call can still be
    // answered — a watch over `~` or the machine is not a shape the tool
    // takes.
    if (draft.source case FileSource(:final paths)) {
      final outside = [
        for (final path in paths)
          if (outsideWorkspaces(
            turn.resolvePath(path),
            turn.workspace,
            turn.projectWorkspace,
          ))
            path,
      ];
      if (outside.isNotEmpty) {
        yield* toolRejected(
          call,
          "A file trigger watches the workspaces: give workspace-relative "
          "or project:-prefixed paths (${outside.join(", ")} reach past "
          "them).",
        );
        return;
      }
    }
    final label = [
      if (draft.name.isNotEmpty) draft.name,
      draft.source.describe(),
    ].join(" — ");
    yield toolCalled(call, label);
    try {
      final stored = await turn.registerTrigger!.register(
        source: draft.source,
        prompt: draft.prompt,
        name: draft.name,
        member: draft.member,
      );
      yield toolOk(call, _setAnswer(stored));
    } catch (e) {
      yield toolFailed(call, "The trigger could not be set: $e");
    }
  }

  /// What registration says back: the id every later call speaks, and the
  /// source's own description — one wording of what was armed, shared with
  /// the settings row and the fire's reason rather than a second here.
  static String _setAnswer(Trigger stored) =>
      "Trigger ${stored.id} set. "
      "${stored.member == null ? "" : "Fires addressed to @${stored.member}. "}"
      "${stored.source.describe()}."
      "${stored.source is FileSource ? " Fires only while the app is running." : ""}";
}

/// Remove one of this chat's own triggers, by id as `trigger_list` speaks
/// it. Another chat's is not here to remove, and neither is a user-set one:
/// the tools speak for the chat that registered their targets.
class TriggerRemoveTool extends _TriggerTool {
  TriggerRemoveTool(super.offer);

  @override
  String get name => triggerRemoveName;

  @override
  String get description =>
      "Remove one of this chat's own triggers, by the "
      "id trigger_list answered. Only what this chat registered is removable "
      "here.";

  @override
  Map<String, dynamic> get schema => const {
    "type": "object",
    "properties": {
      "id": {"type": "string", "description": "The id trigger_list answered."},
    },
    "required": ["id"],
  };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final registry = turn.registerTrigger!;
    final id = stringArg(call.argumentsJson, "id");
    if (id == null) {
      yield* toolRejected(
        call,
        'The $triggerRemoveName tool takes {"id": "<trigger id>"}; that '
        "argument was missing.",
      );
      return;
    }
    yield toolCalled(call, id);
    final own = (await registry.own()).where((t) => t.id == id).toList();
    if (own.isEmpty) {
      yield toolFailed(
        call,
        "No trigger with that id was registered by this "
        "chat. $triggerListName lists what may be removed.",
      );
      return;
    }
    await registry.remove(id);
    yield toolOk(call, "Trigger $id removed.");
  }
}

/// The triggers this chat registered, with what each is waiting for.
class TriggerListTool extends _TriggerTool {
  TriggerListTool(super.offer);

  @override
  String get name => triggerListName;

  @override
  String get description =>
      "List the triggers this chat registered, with "
      "their ids and next fires. What may be removed named here.";

  @override
  Map<String, dynamic> get schema => const {"type": "object", "properties": {}};

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    yield toolCalled(call);
    final own = await turn.registerTrigger!.own();
    if (own.isEmpty) {
      yield toolOk(call, "No triggers registered for this chat.");
      return;
    }
    final lines = [
      for (final trigger in own)
        "- ${trigger.id}: ${trigger.name.isEmpty ? "(unnamed)" : trigger.name}"
            "${trigger.member == null ? "" : " → @${trigger.member}"}"
            " — ${trigger.source.describe()}"
            "${_whenLine(trigger)}",
    ];
    yield toolOk(call, lines.join("\n"));
  }

  /// The stored fire time, worded for the answer — what is armed now, not
  /// the anchor a repeating source steps from, which goes stale as it fires
  /// and would tell the model its own trigger is overdue.
  static String _whenLine(Trigger trigger) {
    final at = trigger.nextFireAt;
    return at == null ? "" : ". Next: ${_nextWording(at, trigger)}";
  }

  /// The source's own relative wording where it is on the clock ("in 30
  /// minutes", "Sat 22 Aug, daily" from the *next* occurrence), the plain
  /// moment otherwise. [TriggerSource.describe] reads the anchor, so the
  /// schedule has to be re-worded here against the stored time.
  static String _nextWording(DateTime at, Trigger trigger) {
    final source = trigger.source;
    return switch (source) {
      ScheduleSource(:final repeat) =>
        "${describeFire(at, DateTime.now())}"
            "${repeat == ScheduleRepeat.off ? "" : ", ${repeat.label.toLowerCase()}"}",
      _ => source.describe(),
    };
  }
}

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
  return TimerSource(
    duration: Duration(seconds: seconds),
    registeredAt: _draftAnchor,
  );
}

/// The parse's placeholder for a timer's anchor: the epoch, a moment no
/// registry keeps. `registeredAt` is required by the model's constructor; a
/// draft carries a duration alone, so this stands where nothing reads it —
/// the registry re-dates the source before anything is stored, and
/// `nextAfter` on a draft is never asked.
final _draftAnchor = DateTime.fromMillisecondsSinceEpoch(0);

TriggerSource? _fileSource(Map<String, dynamic> args) {
  final raw = args["paths"];
  if (raw is! List || raw.isEmpty || raw.any((p) => p is! String)) return null;
  final paths = raw.cast<String>().toList();
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
