import "chat_meta.dart";
import "permission.dart";
import "temp_chat_ttl.dart";
import "date_words.dart" show describeFire;

/// How often a schedule repeats. Declaration order is the order the editor
/// offers them in.
enum ScheduleRepeat {
  off("Does not repeat"),
  hourly("Hourly"),
  daily("Daily"),
  weekly("Weekly"),
  monthly("Monthly");

  const ScheduleRepeat(this.label);

  final String label;
}

/// When a file trigger fires, and over which kinds of change. Declaration
/// order is the order the editor offers them in. The one event vocabulary:
/// what the viewer picks, what the tools accept, and what
/// [FileWatchEvent.kind] carries — the platform watcher's own shapes are
/// translated at [IoFileWatches], the edge, and nothing inside matches by
/// string names.
enum FileEvent {
  create("Created"),
  change("Changed"),
  delete("Deleted"),
  move("Moved");

  const FileEvent(this.label);

  final String label;

  /// Throws on a name this build does not know: the tool's parse wants the
  /// refusal. A stored list reads tolerantly instead, in [Trigger.fromJson].
  static FileEvent fromName(String? name) =>
      values.asNameMap()[name] ?? (throw ArgumentError.value(name, "event"));
}

/// What sets a trigger off. Data, and nothing but: which behaviour watches
/// for what is [TriggerKind]'s (see `trigger_kinds.dart`), so the model
/// knows nothing of timers or watchers.
sealed class TriggerSource {
  const TriggerSource();

  Map<String, dynamic> toJson();

  /// When this source is next due, or null where it never is — one shot
  /// behind its time, a timer elapsed, a file source (which is never on the
  /// clock). Whoever changes when a trigger fires recomputes through this;
  /// the stored [Trigger.nextFireAt] is what a boot receiver reads.
  DateTime? nextAfter(DateTime after);

  /// A description the trigger row, the editor and the tools' results read:
  /// what this source is, in the user's own words. [now] is the moment a
  /// relative wording ("today") is judged against — the caller's clock, not
  /// the wall's, the same steerability everything else date-shaped here has.
  String describe({DateTime? now});
}

/// A wall-clock moment, repeating or not: the reminder shape generalized.
///
/// [at] is the anchor the recurrence steps from, in local time — a monthly
/// one keeps its day of the month, clamped into months too short for it.
class ScheduleSource extends TriggerSource {
  const ScheduleSource({required this.at, this.repeat = ScheduleRepeat.off});

  final DateTime at;
  final ScheduleRepeat repeat;

  @override
  DateTime? nextAfter(DateTime after) =>
      occurrenceAfter(repeat, at, after);

  @override
  String describe({DateTime? now}) {
    final when = describeFire(at, now ?? DateTime.now());
    return switch (repeat) {
      ScheduleRepeat.off => when,
      _ => "$when, ${repeat.label.toLowerCase()}",
    };
  }

  @override
  Map<String, dynamic> toJson() => {
        "kind": "schedule",
        "at": at.toIso8601String(),
        if (repeat != ScheduleRepeat.off) "repeat": repeat.name,
      };

  /// Calendar arithmetic, not fixed durations: a daily one stays at its
  /// wall-clock time across a DST shift. Bounded walk — every step moves
  /// forward one whole period, so this ends.
  static DateTime? occurrenceAfter(
      ScheduleRepeat repeat, DateTime at, DateTime after) {
    if (repeat == ScheduleRepeat.off) {
      return after.isBefore(at) ? at : null;
    }
    if (after.isBefore(at)) return at;
    var t = at;
    while (true) {
      t = switch (repeat) {
        ScheduleRepeat.hourly =>
          DateTime(t.year, t.month, t.day, t.hour + 1, at.minute),
        ScheduleRepeat.daily =>
          DateTime(t.year, t.month, t.day + 1, at.hour, at.minute),
        ScheduleRepeat.weekly =>
          DateTime(t.year, t.month, t.day + 7, at.hour, at.minute),
        ScheduleRepeat.monthly => _monthAfter(t, at),
        ScheduleRepeat.off => throw StateError("unreachable"),
      };
      if (t.isAfter(after)) return t;
    }
  }

  /// The same day-of-month in the following month, clamped into it: Jan 31
  /// monthly lands on Feb 28 and is back on Mar 31, because the anchor's own
  /// day is what every step derives from.
  static DateTime _monthAfter(DateTime from, DateTime anchor) {
    var year = from.year;
    var month = from.month + 1;
    if (month > 12) {
      month = 1;
      year++;
    }
    final day = anchor.day.clamp(1, _daysInMonth(year, month));
    return DateTime(year, month, day, anchor.hour, anchor.minute);
  }

  static int _daysInMonth(int year, int month) {
    if (month == 2) return _isLeap(year) ? 29 : 28;
    const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return lengths[month - 1];
  }

  static bool _isLeap(int year) =>
      year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

/// A one-shot countdown from when it was registered: "in thirty minutes".
/// The wall-clock moment it points at is [registeredAt] plus [duration],
/// which is what makes the alarm the schedule's and this one's share: both
/// precompute a [Trigger.nextFireAt] a boot receiver can arm. [registeredAt]
/// is set by whoever registers — the tool parse carries none of its own, so
/// no stored countdown is anchored anywhere but the registering moment.
class TimerSource extends TriggerSource {
  const TimerSource({required this.duration, required this.registeredAt});

  final Duration duration;

  /// When it was set, local time — the anchor the countdown runs from.
  final DateTime registeredAt;

  @override
  DateTime? nextAfter(DateTime after) {
    final at = registeredAt.add(duration);
    return at.isAfter(after) ? at : null;
  }

  @override
  String describe({DateTime? now}) {
    // Sub-minute first: the tool takes seconds, and a truncated "In 0
    // minutes" tells the model nothing about what it armed.
    if (duration < const Duration(minutes: 1)) {
      return "In ${duration.inSeconds} seconds";
    }
    final minutes = duration.inMinutes;
    if (minutes < 60) {
      final leftover = duration.inSeconds % 60;
      return leftover == 0
          ? "In $minutes minutes"
          : "In $minutes min $leftover sec";
    }
    final hours = duration.inHours;
    final leftover = minutes % 60;
    return leftover == 0
        ? "In $hours hours"
        : "In $hours h $leftover min";
  }

  @override
  Map<String, dynamic> toJson() => {
        "kind": "timer",
        "seconds": duration.inSeconds,
        "registeredAt": registeredAt.toIso8601String(),
      };
}

/// A change under one or more paths. Fires only while the process runs — a
/// file watch is not a system clock, and nothing on any platform re-delivers
/// an inotify event to a process that was not there. On Android the process
/// being frozen holds the events until it thaws; the app closed drops them.
class FileSource extends TriggerSource {
  const FileSource({
    required this.paths,
    this.events = const {
      FileEvent.create,
      FileEvent.change,
      FileEvent.delete,
      FileEvent.move,
    },
    this.cooldown = const Duration(seconds: 5),
  });

  /// The paths to watch, as given — `project:`- or `chat:`-prefixed, relative,
  /// or `~`-expanded, the same shapes the file tools resolve. Resolved where
  /// the watch is built, not here: the model holds none of this at rest.
  final List<String> paths;

  /// Which changes fire. Every kind, where a registration says nothing.
  final Set<FileEvent> events;

  /// How long a trigger stays quiet after it fired, so a burst of writes is
  /// one turn rather than one a line.
  final Duration cooldown;

  @override
  DateTime? nextAfter(DateTime after) => null;

  @override
  String describe({DateTime? now}) =>
      "${paths.length > 1 ? "${paths.length} paths" : paths.first}, "
      "${events.map((e) => e.label.toLowerCase()).toSet().join(" or ")} changes";

  @override
  Map<String, dynamic> toJson() => {
        "kind": "file",
        "paths": paths,
        if (events.length != FileEvent.values.length)
          "events": [for (final e in events) e.name],
        if (cooldown != const Duration(seconds: 5))
          "cooldownSeconds": cooldown.inSeconds,
      };
}

/// One trigger: a prompt run at a moment, after a countdown, or on a file
/// change — in a new headless chat, or in the chat that registered it.
///
/// [nextFireAt] is precomputed rather than derived: the boot receiver reads
/// this file with no engine running, and a second copy of the arithmetic in
/// Kotlin would drift from this one across DST and month ends the way any
/// second copy does.
class Trigger {
  /// [nextFireAt] is what the clock is set against, and null is nothing
  /// armed — a fired one-shot, a timer gone, or a file source. Whoever
  /// changes when a trigger fires recomputes it; the constructor stores what
  /// it is given, so an edit into the past cannot quietly re-arm itself.
  Trigger({
    required this.id,
    required this.name,
    required this.prompt,
    required this.source,
    this.chatId,
    this.member,
    this.project,
    this.tempChatTtl,
    this.enabled = true,
    this.byAgent = false,
    this.lastFiredAt,
    this.nextFireAt,
    this.requestCode,
  });

  final String id;
  final String name;
  final String prompt;
  final TriggerSource source;

  /// Where the turn runs. Null is a new chat, headless — what a schedule the
  /// user set is, and what reminders always were. A chat id is the one that
  /// registered the trigger, whose conversation carries on: its turns are
  /// watched, and are not `headless`.
  final String? chatId;

  /// Which project. Null is the default project, the same null
  /// [projectOrDefault] resolves; [chatId] wins over it where both are set,
  /// the chat being already somewhere.
  final String? project;

  /// The member of an Omada room the fire is addressed to, sigil off —
  /// `researcher`, not `@researcher` — resolved against the project's
  /// library where the prompt is composed, and refused at registration
  /// where the library does not hold them. One shape whatever the target:
  /// a chatless fire makes the headless chat with this member as its first
  /// speaker, a same-chat one queues the prompt on the named member's
  /// FIFO, and either way the routing is the room's own — the mention the
  /// runner composes routes like any message sent. Validation is where the
  /// library happens to be (registration, and the editor's dropdown); a
  /// stored member later deleted is not re-checked, and at fire time a
  /// name the library does not hold is prose, which the room's mention
  /// filter already answers.
  final String? member;

  /// The new chat's own temporary-chat TTL, written straight onto its
  /// `meta.json` — the same field the chat settings page sets, with the same
  /// null meaning inherit the project or app default. Nothing where
  /// [chatId] names the chat: it lives as long as it does.
  final TempChatTtl? tempChatTtl;
  final bool enabled;

  /// Whether an agent registered it — through the trigger tools in its own
  /// chat. The editor marks such a row and refuses to rewrite its prompt:
  /// the conversation holds it.
  final bool byAgent;

  /// Stamped before the turn runs, never after: a crash mid-turn costs a
  /// notification but must not re-run the whole prompt.
  final DateTime? lastFiredAt;

  /// What the clock is armed against, persisted for the boot receiver.
  final DateTime? nextFireAt;

  /// The PendingIntent request code, assigned once at creation by the store
  /// and only for the clock kinds. Derived codes would collide occasionally,
  /// and a collision silently overwrites another trigger's alarm.
  final int? requestCode;

  /// The new chat's `meta.json`: `approveMode` pinned to `never` because
  /// nobody is there to press a banner, the TTL asked for, and `headless` so
  /// every turn on it drops `ask_user` and `task`. A trigger pointed at an
  /// existing chat is watched; its turns run under that chat's own meta.
  ChatMeta get meta => ChatMeta(
        approveMode: ApproveMode.never,
        tempChatTtl: tempChatTtl,
        headless: true,
      );

  /// What a completion notification titles where the trigger carries no
  /// name. One copy of the fallback, so the wording of a nameless trigger
  /// agrees wherever it is said.
  String get title => name.isEmpty ? "Reminder" : name;

  /// What a fire names itself where one line of it is shown — the arms'
  /// notification, the settings tile. One copy of the rule, so what a
  /// nameless trigger reads as agrees wherever it is said.
  String get label => name.isEmpty ? prompt : name;

  Trigger copyWith({
    String? name,
    String? prompt,
    TriggerSource? source,
    String? member,
    bool clearMember = false,
    String? project,
    TempChatTtl? tempChatTtl,
    bool clearTempChatTtl = false,
    bool? enabled,
    DateTime? lastFiredAt,
    DateTime? nextFireAt,
    bool clearNextFireAt = false,
    int? requestCode,
  }) =>
      Trigger(
        id: id,
        name: name ?? this.name,
        prompt: prompt ?? this.prompt,
        source: source ?? this.source,
        chatId: chatId,
        member: clearMember ? null : (member ?? this.member),
        project: project ?? this.project,
        tempChatTtl: clearTempChatTtl ? null : (tempChatTtl ?? this.tempChatTtl),
        enabled: enabled ?? this.enabled,
        byAgent: byAgent,
        lastFiredAt: lastFiredAt ?? this.lastFiredAt,
        nextFireAt: clearNextFireAt ? null : (nextFireAt ?? this.nextFireAt),
        requestCode: requestCode ?? this.requestCode,
      );

  factory Trigger.fromJson(Map<String, dynamic> json) {
    // The source is a map this build wrote, or the flat `at`/`repeat` keys an
    // older one left on the trigger itself — the reminder shape. Held as
    // schedule data rather than migrated: a legacy record is a trigger
    // because the reader says so, the siblingOf bargain.
    final raw = json["source"];
    final source = raw is Map<String, dynamic>
        ? _sourceFrom(raw)
        : _legacySourceFrom(json);
    return Trigger(
      id: json["id"] as String,
      name: json["name"] as String? ?? "",
      prompt: json["prompt"] as String? ?? "",
      source: source,
      chatId: json["chatId"] as String?,
      member: json["member"] as String?,
      project: json["project"] as String?,
      tempChatTtl: TempChatTtl.values.asNameMap()[json["tempChatTtl"]] ??
          // `temporary` is what a build before the TTL field wrote, and false
          // there meant the one TTL a bool could name.
          ((json["temporary"] as bool? ?? true) ? null : TempChatTtl.off),
      byAgent: json["byAgent"] as bool? ?? false,
      enabled: json["enabled"] as bool? ?? true,
      lastFiredAt: _date(json["lastFiredAt"]),
      nextFireAt: _date(json["nextFireAt"]),
      requestCode: json["requestCode"] as int?,
    );
  }

  static TriggerSource _legacySourceFrom(Map<String, dynamic> json) =>
      ScheduleSource(
        at: _date(json["at"]) ?? DateTime(2026),
        // An unknown name is a later build's: fall back, not lose the list.
        repeat: ScheduleRepeat.values.asNameMap()[json["repeat"]] ??
            ScheduleRepeat.off,
      );

  static TriggerSource _sourceFrom(Map<String, dynamic> json) {
    final kind = json["kind"] as String?;
    return switch (kind) {
      "timer" => TimerSource(
          duration: Duration(seconds: json["seconds"] as int? ?? 0),
          registeredAt: _date(json["registeredAt"]) ?? DateTime(2026),
        ),
      "file" => _fileSourceFrom(json),
      // An unknown kind is a file written by a later build: schedule is
      // what a trigger used to be, and a fall back beats a lost list.
      _ => _legacySourceFrom(json),
    };
  }

  static FileSource _fileSourceFrom(Map<String, dynamic> json) {
    final rawEvents = json["events"] as List?;
    // A name this build does not know reads as a change rather than failing
    // the record; what is not a string is dropped.
    return FileSource(
      paths: [
        for (final p in json["paths"] as List? ?? const [])
          if (p is String) p,
      ],
      // Said nothing: everything.
      events: rawEvents == null
          ? FileEvent.values.toSet()
          : {
              for (final e in rawEvents)
                if (e is String)
                  FileEvent.values.asNameMap()[e] ?? FileEvent.change,
            },
      cooldown: Duration(
          seconds: json["cooldownSeconds"] is int
              ? json["cooldownSeconds"] as int
              : const Duration(seconds: 5).inSeconds),
    );
  }

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "prompt": prompt,
        "source": source.toJson(),
        if (chatId != null) "chatId": chatId,
        if (member != null) "member": member,
        if (project != null) "project": project,
        if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
        if (byAgent) "byAgent": true,
        if (!enabled) "enabled": false,
        if (lastFiredAt != null) "lastFiredAt": lastFiredAt!.toIso8601String(),
        if (nextFireAt != null) "nextFireAt": nextFireAt!.toIso8601String(),
        if (requestCode != null) "requestCode": requestCode,
      };

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.tryParse(value as String);
}

/// What registering this source at [now] must refuse, or null where it
/// arms honestly: a one-shot whose moment is already past arms against
/// nothing and would never fire — the editor refuses that shape at save
/// ("Pick a time in the future"), and the tool owes the model the same
/// refusal, as a fixable error it can correct with a later moment. A
/// repeating schedule's occurrences are ahead of it, and a timer counts
/// from the registering moment only, so neither is ever past.
String? triggerScheduleProblem(TriggerSource source, DateTime now) =>
    source is ScheduleSource &&
            source.repeat == ScheduleRepeat.off &&
            !source.at.isAfter(now)
        ? "a one-shot at or before now would never fire; schedule it for a "
            "future moment"
        : null;
