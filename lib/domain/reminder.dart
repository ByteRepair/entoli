import "temp_chat_ttl.dart";

/// How often a reminder repeats. Declaration order is the order the editor
/// offers them in.
enum ReminderRepeat {
  off("Does not repeat"),
  hourly("Hourly"),
  daily("Daily"),
  weekly("Weekly"),
  monthly("Monthly");

  const ReminderRepeat(this.label);

  final String label;

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole list — the bargain [TempChatTtl.fromName]
  /// makes.
  static ReminderRepeat fromName(String? name) =>
      values.firstWhere((t) => t.name == name, orElse: () => ReminderRepeat.off);
}

/// One reminder: a prompt run in a new chat at a time, on Android's clock when
/// the app is not running and by an in-process timer when it is.
///
/// [nextFireAt] is precomputed rather than derived: the boot receiver reads
/// this file with no engine running, and a second copy of the recurrence math
/// in Kotlin would drift from this one across DST and month ends the way any
/// second copy does.
class Reminder {
  /// [nextFireAt] is what the clock is set against, and null is nothing
  /// armed — a fired one-shot, or a reminder switched off. Whoever changes
  /// when a reminder fires recomputes it; the constructor stores what it is
  /// given, so an edit into the past cannot quietly re-arm itself.
  Reminder({
    required this.id,
    required this.name,
    required this.prompt,
    required this.at,
    this.repeat = ReminderRepeat.off,
    this.project,
    this.tempChatTtl,
    this.enabled = true,
    this.lastFiredAt,
    this.nextFireAt,
    this.requestCode,
  });

  final String id;
  final String name;
  final String prompt;

  /// When it was set to fire, in local time — the anchor the recurrence steps
  /// from, so a monthly one keeps its day of the month.
  final DateTime at;
  final ReminderRepeat repeat;

  /// Which project the chat is created in. Null is the default project, the
  /// same null [projectOrDefault] resolves.
  final String? project;

  /// The chat's own temporary-chat TTL, written straight onto its `meta.json`
  /// — the same field the chat settings page sets, with the same null meaning
  /// inherit the project or app default.
  final TempChatTtl? tempChatTtl;
  final bool enabled;

  /// Stamped before the turn runs, never after: a crash mid-turn costs a
  /// notification but must not re-run the whole prompt.
  final DateTime? lastFiredAt;

  /// What the clock is armed against, persisted for the boot receiver.
  final DateTime? nextFireAt;

  /// The PendingIntent request code, assigned once at creation by the store.
  /// Derived codes would collide occasionally, and a collision silently
  /// overwrites another reminder's alarm.
  final int? requestCode;

  Reminder copyWith({
    String? name,
    String? prompt,
    DateTime? at,
    ReminderRepeat? repeat,
    String? project,
    TempChatTtl? tempChatTtl,
    bool clearTempChatTtl = false,
    bool? enabled,
    DateTime? lastFiredAt,
    bool clearLastFiredAt = false,
    DateTime? nextFireAt,
    bool clearNextFireAt = false,
    int? requestCode,
  }) =>
      Reminder(
        id: id,
        name: name ?? this.name,
        prompt: prompt ?? this.prompt,
        at: at ?? this.at,
        repeat: repeat ?? this.repeat,
        project: project ?? this.project,
        tempChatTtl: clearTempChatTtl ? null : (tempChatTtl ?? this.tempChatTtl),
        enabled: enabled ?? this.enabled,
        lastFiredAt: clearLastFiredAt ? null : (lastFiredAt ?? this.lastFiredAt),
        nextFireAt: clearNextFireAt ? null : (nextFireAt ?? this.nextFireAt),
        requestCode: requestCode ?? this.requestCode,
      );

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
        id: json["id"] as String,
        name: json["name"] as String? ?? "",
        prompt: json["prompt"] as String? ?? "",
        at: DateTime.parse(json["at"] as String),
        repeat: ReminderRepeat.fromName(json["repeat"] as String?),
        project: json["project"] as String?,
        // `temporary` is what a build before the TTL field wrote, and false
        // there meant the one TTL a bool could name.
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?) ??
            ((json["temporary"] as bool? ?? true) ? null : TempChatTtl.off),
        enabled: json["enabled"] as bool? ?? true,
        lastFiredAt: _date(json["lastFiredAt"]),
        nextFireAt: _date(json["nextFireAt"]),
        requestCode: json["requestCode"] as int?,
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "prompt": prompt,
        "at": at.toIso8601String(),
        if (repeat != ReminderRepeat.off) "repeat": repeat.name,
        if (project != null) "project": project,
        if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
        if (!enabled) "enabled": false,
        if (lastFiredAt != null) "lastFiredAt": lastFiredAt!.toIso8601String(),
        if (nextFireAt != null) "nextFireAt": nextFireAt!.toIso8601String(),
        if (requestCode != null) "requestCode": requestCode,
      };

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.tryParse(value as String);

  /// Due now or overdue — both are catch-up's business. Null [nextFireAt] is
  /// nothing armed: a fired one-shot, or a reminder switched off.
  bool dueBy(DateTime after) =>
      enabled && nextFireAt != null && !after.isBefore(nextFireAt!);

  /// The first occurrence strictly after [after], or null where [repeat] is
  /// off. Calendar arithmetic, not fixed durations: a daily reminder stays at
  /// its wall-clock time across a DST shift, and a monthly one keeps its day
  /// of the month, clamped into months too short for it.
  DateTime? nextOccurrence(DateTime after) =>
      occurrenceAfter(repeat, at, after);

  /// The static half of [nextOccurrence], so an editor can ask about a
  /// reminder it has not built yet.
  static DateTime? occurrenceAfter(
      ReminderRepeat repeat, DateTime at, DateTime after) {
    if (repeat == ReminderRepeat.off) {
      return after.isBefore(at) ? at : null;
    }
    if (after.isBefore(at)) return at;
    var t = at;
    // Bounded walk: every step moves forward one whole period, so this ends.
    // A reminder years past due walks its whole history once, which is fine —
    // the counts are thousands at worst.
    while (true) {
      t = switch (repeat) {
        ReminderRepeat.hourly => DateTime(t.year, t.month, t.day, t.hour + 1, at.minute),
        ReminderRepeat.daily => DateTime(t.year, t.month, t.day + 1, at.hour, at.minute),
        ReminderRepeat.weekly => DateTime(t.year, t.month, t.day + 7, at.hour, at.minute),
        ReminderRepeat.monthly => _monthAfter(t, at),
        ReminderRepeat.off => throw StateError("unreachable"),
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

  static bool _isLeap(int year) => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}
