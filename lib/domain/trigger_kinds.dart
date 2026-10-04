import "dart:async";

import "package:clock/clock.dart";

import "reminder_alarms.dart";
import "trigger.dart";

/// What a kind reports to the manager — which trigger fired, and the words
/// the fire says for itself. The reason rides in the prompt the runner sends
/// rather than in a side channel, so the log says why a turn started.
class TriggerFire {
  const TriggerFire(this.triggerId, this.reason, {this.late_ = false});

  final String triggerId;
  final String reason;

  /// Whether the fire arrived well past its time — a trigger missed while
  /// the process was dead, caught up at launch. The completion's wording
  /// says so; an exact alarm, arriving within seconds, does not.
  final bool late_;
}

/// The behaviour of one source kind: what watches for the source becoming
/// true, and what to call when it is. One registration in
/// [TriggerManager]'s registry; nothing in the manager switches on kind.
///
/// A kind sees the model and its own port and nothing else. It never runs a
/// turn, never touches the list, never notifies — the manager is the one
/// that claims a fire, stamps the trigger, and hands the reason to the
/// runner.
abstract class TriggerKind {
  /// Whether this trigger is this kind's — the registry's dispatch, read
  /// off the source rather than a stored name.
  bool matches(Trigger trigger);

  /// Whether this kind has anything waiting for this trigger — a schedule
  /// its `nextFireAt`, a file source its paths, an off one nothing. False
  /// lets the manager skip building a watch it would never read.
  bool armed(Trigger trigger);

  /// What to watch. Answers a stream of fires that covers the triggers
  /// given, which are exactly [matches] and [armed] over one snapshot of
  /// the list: the manager swaps the list under one subscription per
  /// reload rather than one per trigger. A clock kind's stream carries its
  /// own timer, its alarm diff, and its catch-up of what passed while
  /// nothing was running; a file kind's, its watchers, each debounced.
  ///
  /// A kind holds the whole lifetime of what it builds: cancelled when the
  /// manager drops the subscription, which is what [watch]'s answer owes
  /// its callers.
  Stream<TriggerFire> watch(List<Trigger> triggers, Clock clock);

  /// Hand a fire back rather than run it, where the platform will not hold
  /// the process for the turn — answered before the runner is called, once
  /// per fire. False where there is nothing to hand back to: a desktop has
  /// no alarm, a file source no clock, and running it merely killable is
  /// where every such platform already is.
  Future<bool> defer(Trigger trigger);

  /// The deferred fire ran (or was given up on); it may be handed back
  /// again next time. A no-op for every kind that defers nothing.
  void ran(Trigger trigger);

  /// This source's next moment, after [after], through its own arithmetic —
  /// what the manager stamps as [Trigger.nextFireAt] once a fire has run.
  /// Null where the kind is never on the clock.
  DateTime? nextFire(Trigger trigger, DateTime after);

  /// The description the editor's source picker reads: what this kind is,
  /// in the user's own words.
  String get label;
}

/// What the wall-clock kinds share: the in-process timer aimed at the
/// nearest armed `nextFireAt`, catch-up for what passed while nothing was
/// running, the alarm diff that lets Android fire with the process dead,
/// and the defer-to-alarm dance for a fire the platform cannot hold a turn
/// under.
///
/// Two facts make the timer this class's own rather than the manager's. It
/// fires on time whether or not anyone is looking, and off screen on
/// Android the only moment the process may take the hold that keeps it
/// alive is inside the broadcast its own alarm delivers — so a fire nothing
/// can hold is re-armed for the time it was already due, which
/// [ReminderAlarms.schedule] delivers at once: the receiver holds the
/// process and the fire comes back through the manager seconds later,
/// held. And a watch is torn down on every list change, which is exactly
/// when the diff has to run — one place, not two kept level by hand.
abstract class ClockKind extends TriggerKind {
  ClockKind(this.alarms);

  /// The alarm port's scheduling half. Notify is not here: the manager is
  /// where a fire answers for itself, and a kind has no conversation to
  /// answer about.
  final ReminderAlarms alarms;

  /// What is currently registered with the system, by request code — the
  /// diff between this and the watch's snapshot is what [_diffAlarms]
  /// cancels.
  final Map<int, DateTime> _armed = {};

  /// Triggers handed back to the alarm once already, without a run in
  /// between. Coming back still unable to hold means the broadcast is not
  /// getting a hold either — exact alarms denied — and by then running it
  /// merely killable beats not running it at all.
  final Set<String> _deferred = {};

  /// How long past its time a fire may arrive without counting as missed.
  /// An exact alarm lands within seconds; an inexact one can be minutes
  /// late under Doze, which is honest lateness and worth saying.
  static const late = Duration(minutes: 2);

  @override
  bool armed(Trigger trigger) =>
      trigger.enabled && trigger.nextFireAt != null;

  @override
  DateTime? nextFire(Trigger trigger, DateTime after) {
    final raw = trigger.source;
    return raw is ScheduleSource
        ? ScheduleSource.occurrenceAfter(raw.repeat, raw.at, after)
        : raw is TimerSource
            ? raw.nextAfter(after)
            : null;
  }

  @override
  void ran(Trigger trigger) => _deferred.remove(trigger.id);

  @override
  Stream<TriggerFire> watch(List<Trigger> triggers, Clock clock) async* {
    // The alarm diff first: the boot receiver re-arms what it reads, and
    // whatever the list changed is said to the system here.
    await _diffAlarms(triggers);
    // Catch-up: what passed while nothing was running fires now. Overdue by
    // more than [late] arrives worded as late, the way an exact alarm never
    // is. Nothing armed is silence, and silence is what a no-fire launch
    // holds the process for.
    final now = clock.now();
    for (final trigger in triggers) {
      final at = trigger.nextFireAt;
      if (at != null && !at.isAfter(now)) {
        yield TriggerFire(trigger.id, reasonOf(trigger),
            late_: now.difference(at) > late);
      }
    }
    // One timer, aimed at the nearest armed fire. Rearsm itself on every
    // tick until the manager drops the watch, which is a list change.
    while (true) {
      final nextNearest = _nearest(triggers, clock.now());
      if (nextNearest == null) return;
      final wait = nextNearest.difference(clock.now());
      await Future<void>.delayed(wait.isNegative ? Duration.zero : wait);
      final again = clock.now();
      for (final trigger in triggers) {
        final at = trigger.nextFireAt;
        if (at != null && !at.isAfter(again)) {
          yield TriggerFire(trigger.id, reasonOf(trigger),
              late_: again.difference(at) > late);
        }
      }
      // A yield above may have taken a while to be consumed; the next
      // wait is computed from the snapshot as it stands. A trigger fired
      // here is stamped by the manager, and the stamp re-enters the
      // manager's reload — which rebuilds the watch, ending this loop.
    }
  }

  DateTime? _nearest(List<Trigger> triggers, DateTime after) {
    DateTime? nearest;
    for (final trigger in triggers) {
      final at = trigger.nextFireAt;
      if (at != null && at.isAfter(after) && (nearest == null || at.isBefore(nearest))) {
        nearest = at;
      }
    }
    return nearest;
  }

  /// What the fire says set it off: the schedule or its next recurrence,
  /// in the words the user set it with.
  String reasonOf(Trigger trigger) {
    final source = trigger.source;
    return source is ScheduleSource
        ? "schedule: ${source.describe()}"
        : source is TimerSource
            ? "timer: ${source.describe()}"
            : "the clock reached its time";
  }

  /// Re-register every armed trigger with the system, cancelling whatever
  /// the snapshot no longer asks for. Idempotent; nothing to ask where the
  /// platform keeps no clock — the whole diff would be round trips into
  /// no-ops.
  Future<void> _diffAlarms(List<Trigger> triggers) async {
    if (!alarms.available || !alarms.schedules) return;
    final wanted = <int, DateTime>{
      for (final t in triggers)
        if (t.nextFireAt != null && t.requestCode != null)
          t.requestCode!: t.nextFireAt!,
    };
    for (final code in _armed.keys) {
      if (!wanted.containsKey(code)) await alarms.cancel(code);
    }
    // _armed is the diff against what is already registered, so an
    // unchanged fire time is a no-op skipped here rather than a round trip.
    for (final entry in wanted.entries) {
      if (_armed[entry.key] != entry.value) {
        await alarms.schedule(entry.key, entry.value);
      }
    }
    _armed
      ..clear()
      ..addAll(wanted);
  }

  @override
  Future<bool> defer(Trigger trigger) async {
    if (!alarms.available || trigger.requestCode == null) return false;
    if (_deferred.contains(trigger.id)) return false;
    if (await alarms.canHoldTurn()) return false;
    _deferred.add(trigger.id);
    final at = trigger.nextFireAt;
    if (at != null) await alarms.schedule(trigger.requestCode!, at);
    return true;
  }
}

/// The schedule source's kind: [ScheduleSource]'s recurrence against the
/// system clock.
class ScheduleKind extends ClockKind {
  ScheduleKind(super.alarms);

  @override
  bool matches(Trigger trigger) => trigger.source is ScheduleSource;

  @override
  bool armed(Trigger trigger) =>
      matches(trigger) && super.armed(trigger);

  @override
  String get label => "Schedule";
}

/// The timer source's kind: a one-shot countdown. Fires exactly as a
/// schedule does — the alarm arithmetic differs, the manager's path is the
/// same one — so it shares [ClockKind] with nothing of its own beyond the
/// match.
class TimerKind extends ClockKind {
  TimerKind(super.alarms);

  @override
  bool matches(Trigger trigger) => trigger.source is TimerSource;

  @override
  bool armed(Trigger trigger) =>
      matches(trigger) && super.armed(trigger);

  @override
  String get label => "Timer";
}