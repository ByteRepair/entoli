import "dart:convert";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:uuid/uuid.dart";

import "../../domain/date_words.dart" show describeFire, shortDate;
import "../../domain/project.dart";
import "../../domain/temp_chat_ttl.dart";
import "../../domain/trigger.dart";
import "../../providers.dart";

/// What the system says of the two permissions a trigger leans on. The rows
/// lead to the system's settings, where the answers can change while the app
/// is behind, so they are asked again each time it comes back.
final triggerPermissionsProvider =
    FutureProvider<({bool notifications, bool exact})>((ref) async {
      ref.watch(appResumesProvider);
      final alarms = ref.watch(reminderAlarmsProvider);
      return (
        notifications: await alarms.notificationsAllowed(),
        exact: await alarms.exactAllowed(),
      );
    });

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
        TimerSource(:final duration)
            when duration < const Duration(minutes: 1) =>
          "Set a countdown of at least a minute.",
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
        clearProject: project == null,
        member: member,
        clearMember: member == null,
        tempChatTtl: tempChatTtl,
        clearTempChatTtl: tempChatTtl == null,
        enabled: true,
        clearNextFireAt: true,
      )
      .copyWith(nextFireAt: set.nextAfter(now));
}

/// What a trigger's row says of it: when it next fires, what it watches,
/// who it is addressed to and where its chat goes; or when it last fired.
/// [exact] false is a schedule the system may fire late.
String triggerSummary(
  Trigger trigger, {
  required List<String> projects,
  required DateTime now,
  required bool exact,
}) {
  final project = projectOrDefault(trigger.project, projects);
  final said = [
    if (trigger.enabled && trigger.nextFireAt != null)
      "${exact ? "" : "approx. "}${describeFire(trigger.nextFireAt!, now)}",
    if (trigger.enabled && trigger.nextFireAt == null)
      if (trigger.source case FileSource(:final paths))
        "File: ${paths.join(", ")}",
    if (trigger.source case ScheduleSource(:final repeat)) repeat.label,
    if (trigger.member != null) "@${trigger.member}",
    if (project != null) projectLabel(project),
    if (trigger.byAgent) "Set by the agent",
  ].join(" · ");
  return said.isNotEmpty
      ? said
      : trigger.lastFiredAt == null
      ? "Never fired"
      : "Last fired ${shortDate(trigger.lastFiredAt!)}";
}

enum TriggerKind { schedule, timer, file }

TriggerKind triggerKindOf(TriggerSource source) => switch (source) {
  ScheduleSource() => TriggerKind.schedule,
  TimerSource() => TriggerKind.timer,
  FileSource() => TriggerKind.file,
};

/// A trigger being added or edited, as its editor holds it. Each kind keeps
/// what was set on it while another is showing, so switching to Countdown
/// and back loses nothing. One the agent registered is shown and not saved:
/// its switch and its delete are what is left.
class TriggerDraft {
  TriggerDraft(Trigger? trigger, {required DateTime now})
    : this._(
        trigger,
        now,
        trigger?.source ?? ScheduleSource(at: _nextHour(now)),
      );

  TriggerDraft._(this.trigger, this.now, TriggerSource source)
    : name = trigger?.name ?? "",
      prompt = trigger?.prompt ?? "",
      source = source,
      _initialSource = _json(source),
      project = trigger?.project,
      member = trigger?.member,
      tempChatTtl = trigger?.tempChatTtl;

  final Trigger? trigger;
  final DateTime now;

  String name;
  String prompt;
  TriggerSource source;

  /// As stored: a project deleted since is read as the default at save.
  String? project;
  String? member;
  TempChatTtl? tempChatTtl;

  final _kept = <TriggerKind, TriggerSource>{};

  final String _initialSource;

  bool get isNew => trigger == null;
  bool get registered => trigger?.byAgent ?? false;

  /// A new schedule defaults to the next whole hour, so picking a time is
  /// one spin rather than starting from now and a few minutes.
  static DateTime _nextHour(DateTime now) =>
      DateTime(now.year, now.month, now.day, now.hour + 1);

  TriggerKind get kind => triggerKindOf(source);

  /// Switches to [kind]: what it held when it was last left, else what the
  /// trigger was saved with, else the kind's default.
  set kind(TriggerKind kind) {
    if (kind == this.kind) return;
    _kept[this.kind] = source;
    final saved = trigger?.source;
    source =
        _kept[kind] ??
        (saved != null && triggerKindOf(saved) == kind
            ? saved
            : switch (kind) {
                TriggerKind.schedule => ScheduleSource(at: _nextHour(now)),
                TriggerKind.timer => TimerSource(
                  duration: const Duration(minutes: 30),
                  registeredAt: now,
                ),
                TriggerKind.file => const FileSource(paths: []),
              });
  }

  static String _json(TriggerSource source) => jsonEncode(source.toJson());

  bool get edited =>
      name != (trigger?.name ?? "") ||
      prompt != (trigger?.prompt ?? "") ||
      _json(source) != _initialSource ||
      project != trigger?.project ||
      member != trigger?.member ||
      tempChatTtl != trigger?.tempChatTtl;

  /// Why it cannot be saved, or null where it can.
  String? get refusal => registered
      ? null
      : triggerRefusal(source, prompt, isNew: isNew, now: now);

  /// The trigger saved, at [at], into one of [projects] or the default.
  Trigger build({required DateTime at, required List<String> projects}) =>
      savedTrigger(
        trigger,
        name: name,
        prompt: prompt,
        source: source,
        project: projectOrDefault(project, projects),
        member: member,
        tempChatTtl: tempChatTtl,
        now: at,
      );
}
