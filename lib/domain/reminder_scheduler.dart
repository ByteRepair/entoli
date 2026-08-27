import "dart:async";

import "reminder.dart";
import "reminder_alarms.dart";
import "reminder_runner.dart";

/// What the scheduler needs from whoever owns the reminder list. Read on use
/// and written whole: the list is small, and a second copy of it anywhere
/// would drift from the one on disk.
abstract interface class ReminderList {
  List<Reminder> get reminders;

  /// Replace the list, persisting it. Whatever changes alarms — an edit, an
  /// enable, a delete — comes back through [ReminderScheduler.reload].
  Future<void> write(List<Reminder> reminders);

  /// Replace the one reminder whose id matches, keeping list order. Every
  /// change to a single reminder goes through this rather than reaching into
  /// [reminders] to splice, so the list owns how it is kept.
  Future<void> replace(Reminder reminder);
}

/// The in-process half of scheduling: one timer aimed at the nearest armed
/// reminder, catch-up for what passed while nothing was running, and the alarm
/// sync that lets Android fire when the process is dead.
///
/// **Dart is the sole arbiter of what runs.** Kotlin only ever nudges — an id
/// stashed beside [ReminderAlarms.takeFired] — so whichever of the three
/// triggers notices first (this timer, a nudge, startup catch-up) stamps the
/// reminder and runs it, and the others find the stamp moved.
class ReminderScheduler {
  ReminderScheduler({
    required this.alarms,
    required this.runner,
    required this.list,
    required this.projects,
  });

  final ReminderAlarms alarms;
  final ReminderRuns runner;
  final ReminderList list;
  final Future<List<String>> Function() projects;

  Timer? _timer;
  StreamSubscription<void>? _nudges;

  /// Reminders with a turn running. A second trigger arriving while one is
  /// under way finds the id here and stands down.
  final Set<String> _runningIds = {};

  /// Reminders handed back to the alarm once already — see [_deferToAlarm].
  final Set<String> _deferred = {};

  /// What is currently registered with the system, by request code — the diff
  /// between this and the list is what [sync] cancels.
  final Map<int, DateTime> _armed = {};

  /// Started once, beside the sweep timer; it wires itself up rather than
  /// waiting to be watched.
  Future<void> start() async {
    _nudges = alarms.fired.listen((_) => onNudged());
    await reload();
  }

  void dispose() {
    _timer?.cancel();
    _nudges?.cancel();
  }

  /// The list changed: re-register everything with the system, run anything
  /// the change made due, and re-aim the timer.
  ///
  /// The release at the end is for the launch this is the first call of: an
  /// alarm that woke the process holds it, and by here whatever it woke us for
  /// has run. Every other caller is an edit, where there is no hold to release
  /// and this says so to a platform that already agrees.
  ///
  /// It is a no-op while a fire's turn is running: a fire stamps the reminder
  /// list mid-turn, which re-enters here, and releasing then would drop the
  /// receiver's hold before the turn's own foreground-service hold has
  /// registered. See "Waking for a reminder" in `android/CLAUDE.md`.
  Future<void> reload() async {
    await sync();
    await catchUp();
    _arm();
    if (_runningIds.isEmpty) await alarms.doneFiring();
  }

  /// The system noticed a fire while Dart was not listening — or while it was,
  /// which is the same nudge either way. The ids are advisory only.
  Future<void> onNudged() async {
    final ids = await alarms.takeFired();
    if (ids.isEmpty) return;
    await catchUp(only: ids.toSet());
    _arm();
    // The receiver held the process for these; they are dealt with now, one
    // way or the other — unless one is still running, in which case its turn
    // will release once it ends. Releasing here would stop the service before
    // the turn's own hold has registered, and a duplicate exact alarm can
    // deliver a nudge mid-turn.
    if (_runningIds.isEmpty) await alarms.doneFiring();
  }

  void _tick() => unawaited(_onTick());

  Future<void> _onTick() async {
    await catchUp();
    _arm();
  }

  /// Run every reminder due by now — overdue included, which is how a fire
  /// missed while the process was dead is caught up at launch.
  Future<void> catchUp({Set<String>? only}) async {
    final now = DateTime.now();
    final due = [
      for (final r in list.reminders)
        if ((only == null || only.contains(r.id)) &&
            r.dueBy(now) &&
            !_runningIds.contains(r.id))
          r,
    ];
    for (final reminder in due) {
      await _fire(reminder, late: now.difference(reminder.nextFireAt!) > late);
    }
  }

  /// How long past its time a fire may arrive without counting as missed. An
  /// exact alarm lands within seconds; an inexact one can be minutes late
  /// under Doze, which is honest lateness and worth saying.
  static const late = Duration(minutes: 2);

  /// Hand [reminder] back to the alarm rather than run it, where the platform
  /// will not hold the process for its turn. Answers whether it was.
  ///
  /// This timer fires on time whether or not anyone is looking, and off screen
  /// on Android the only moment the process may take the hold that keeps it
  /// alive is inside the broadcast its own alarm delivers. So a fire nothing
  /// can hold is re-armed for the time it was already due, which AlarmManager
  /// delivers at once: the receiver holds the process and the fire comes back
  /// through [onNudged] seconds later, held. A turn nobody holds is one the
  /// system kills halfway, and half a turn costs the user the Continue button.
  ///
  /// Never twice without a run in between. Coming back still unable to hold
  /// means the broadcast is not getting a hold either — a device where exact
  /// alarms are denied — and by then running it merely killable beats not
  /// running it at all.
  Future<bool> _deferToAlarm(Reminder reminder) async {
    if (!alarms.available || reminder.requestCode == null) return false;
    if (_deferred.contains(reminder.id)) return false;
    if (await alarms.canHoldTurn()) return false;
    _deferred.add(reminder.id);
    await alarms.schedule(reminder.requestCode!, reminder.nextFireAt ?? reminder.at);
    return true;
  }

  Future<void> _fire(Reminder reminder, {required bool late}) async {
    // Claimed before the first await, not after: asking the platform whether it
    // can hold us is a round trip, and two triggers either side of it would
    // both find nothing running and both start a turn.
    if (!_runningIds.add(reminder.id)) return;
    try {
      if (await _deferToAlarm(reminder)) return;
      _deferred.remove(reminder.id);
      final result = await runner.run(reminder, await projects());
      await alarms.notify(
        title: reminder.name.isEmpty ? "Reminder" : reminder.name,
        body: switch (result.outcome) {
          ReminderOutcome.done when result.snippet.isNotEmpty =>
            late ? "Ran late.\n\n${result.snippet}" : result.snippet,
          ReminderOutcome.done => late ? "Ran late. Finished." : "Finished.",
          ReminderOutcome.error =>
            late ? "Ran late. The task failed." : "The task failed.",
          ReminderOutcome.aborted => "The task was stopped.",
        },
        chatId: result.chatId,
      );
      final next = reminder.repeat == ReminderRepeat.off
          ? null
          : reminder.nextOccurrence(DateTime.now());
      final fired = reminder.copyWith(lastFiredAt: DateTime.now(), clearNextFireAt: true);
      await list.replace(next == null ? fired : fired.copyWith(nextFireAt: next));
      await sync();
      _arm();
    } finally {
      _runningIds.remove(reminder.id);
    }
  }

  /// Re-register every armed reminder with the system, cancelling whatever the
  /// list no longer asks for. Idempotent, and cheap enough to run after every
  /// mutation rather than tracking who changed what.
  Future<void> sync() async {
    if (!alarms.available) return;
    final wanted = <int, DateTime>{
      for (final r in list.reminders)
        if (r.enabled && r.nextFireAt != null && r.requestCode != null)
          r.requestCode!: r.nextFireAt!,
    };
    for (final code in _armed.keys) {
      if (!wanted.containsKey(code)) await alarms.cancel(code);
    }
    // _armed is the diff against what is already registered, so an unchanged
    // fire time is a no-op skipped here rather than a MethodChannel round trip.
    for (final entry in wanted.entries) {
      if (_armed[entry.key] != entry.value) await alarms.schedule(entry.key, entry.value);
    }
    _armed
      ..clear()
      ..addAll(wanted);
  }

  void _arm() {
    _timer?.cancel();
    DateTime? next;
    for (final r in list.reminders) {
      final at = r.enabled ? r.nextFireAt : null;
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    if (next == null) return;
    final wait = next.difference(DateTime.now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _tick);
  }
}
