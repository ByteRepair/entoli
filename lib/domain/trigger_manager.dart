import "dart:async";

import "package:clock/clock.dart";

import "reminder_alarms.dart";
import "trigger.dart";
import "trigger_kinds.dart";
import "trigger_runner.dart";

/// What the manager needs from whoever owns the trigger list. Read on use and
/// written whole: the list is small, and a second copy of it anywhere would
/// drift from the one on disk.
abstract interface class TriggerList {
  List<Trigger> get triggers;

  /// Replace the list, persisting it. Whatever changes what a kind watches —
  /// an edit, an enable, a delete — comes back through
  /// [TriggerManager.reload].
  Future<void> write(List<Trigger> triggers);

  /// Replace the one trigger whose id matches, keeping list order. Every
  /// change to a single trigger goes through this rather than reaching into
  /// [triggers] to splice, so the list owns how it is kept.
  Future<void> replace(Trigger trigger);
}

/// The room's scheduler side, over every trigger source: a registry of
/// [TriggerKind]s and the one fire path — claim, defer, run, notify, stamp —
/// no kind touches. Adding a source is a registry entry, not a second of any
/// of this; nothing here switches on kind.
///
/// **Dart is the sole arbiter of what runs.** Kotlin only nudges — an id
/// stashed beside [ReminderAlarms.takeFired] — so whichever watcher notices
/// first (a kind's timer, a nudge, a kind's own catch-up) stamps the trigger
/// and runs it, and the others find the stamp moved. A single-flight set
/// keyed by trigger id guards against the overlap, and the id goes into it
/// **before the first await** — asking the platform anything is a round
/// trip, and two watchers either side of one would both find nothing
/// running.
class TriggerManager {
  TriggerManager({
    required this.kinds,
    required this.alarmPort,
    required this.runner,
    required this.list,
    required this.projects,
    this.clock = const Clock(),
  });

  /// The behaviors, one per source kind. Each is asked for its own watch
  /// over its own armed triggers; a kind with nothing armed contributes
  /// silence. A source this build does not know matches no kind and so
  /// never fires — armed against nothing rather than dropped, the list
  /// staying whole.
  final List<TriggerKind> kinds;

  /// Both halves of the alarm port. Scheduling is the kinds' to diff through;
  /// notify is the manager's own, being where a fire answers for itself —
  /// and [ReminderAlarms.doneFiring] rides here rather than in a kind,
  /// because the hold it releases is the launch's, not one kind's.
  final ReminderAlarms alarmPort;
  final TriggerRuns runner;
  final TriggerList list;
  final Future<List<String>> Function() projects;
  final Clock clock;

  /// What a completion notification titles where the trigger carries no
  /// name. A method rather than a constant because a legacy reminder falls
  /// back on "Reminder", which is its word, not the manager's.
  String nameOf(Trigger trigger) =>
      trigger.name.isEmpty ? "Reminder" : trigger.name;

  StreamSubscription<void>? _nudges;
  final Map<TriggerKind, StreamSubscription<TriggerFire>> _watches = {};

  /// Triggers with a turn running. A second watcher arriving while one is
  /// under way finds the id here and stands down.
  final Set<String> _runningIds = {};

  /// Started once; it wires itself up rather than waiting to be watched.
  Future<void> start() async {
    _nudges = alarmPort.fired.listen((_) => onNudged());
    await reload();
  }

  void dispose() {
    _nudges?.cancel();
    for (final sub in _watches.values) {
      unawaited(sub.cancel());
    }
    _watches.clear();
  }

  /// The kind whose source this trigger carries, or null — a source this
  /// build does not know (one written by a later build, or one the registry
  /// holds no entry for) has no behaviour to ask.
  TriggerKind? _kindOf(Trigger trigger) => kinds
      .cast<TriggerKind?>()
      .firstWhere((kind) => kind!.matches(trigger), orElse: () => null);

  /// The list changed: rebuild the kinds' watches — each diffing its own
  /// alarms, catching up its own past-due fires, and aiming its own timer —
  /// then release the launch's hold.
  ///
  /// The release at the end is for the launch this is the first call of: an
  /// alarm that woke the process holds it, and by here whatever it woke us
  /// for has run. Every other caller is an edit, where there is no hold to
  /// release and this says so to a platform that already agrees.
  ///
  /// It is a no-op while a fire's turn is running: a fire stamps the trigger
  /// list mid-turn, which re-enters here, and releasing then would drop the
  /// receiver's hold before the turn's own foreground-service hold has
  /// registered. See "Waking for a reminder" in `android/CLAUDE.md`.
  Future<void> reload() async {
    _rewatch();
    await _drainWatches();
    if (_runningIds.isEmpty) await alarmPort.doneFiring();
  }

  /// Every kind's watch rebuilt from the list as it stands. A kind's watch
  /// answers synchronously begun; the fires it starts with — catch-up — are
  /// drained before this returns, so `start()` has run what was overdue by
  /// the time the caller moves on.
  void _rewatch() {
    for (final sub in _watches.values) {
      unawaited(sub.cancel());
    }
    _watches.clear();
    for (final kind in kinds) {
      final ofKind = [
        for (final t in list.triggers)
          if (kind.matches(t) && kind.armed(t)) t,
      ];
      _watches[kind] = kind.watch(ofKind, clock).listen(_onFire);
    }
  }

  /// Wait out the fires a rebuilt watch opens with — catch-up — so reload's
  /// caller comes back to a settled room. The watches' buffers hold later
  /// fires for the next drain; catch-up is these alone.
  Future<void> _drainWatches() async {
    // One round: a fire's own stamp re-enters reload, which rebuilds the
    // watches again; the single-flight set makes a true re-fire a stand-down.
    await _pump();
  }

  /// Let every watch's streamed fires be delivered, then stop.
  Future<void> _pump() => Future<void>.delayed(Duration.zero);

  void _onFire(TriggerFire fire) {
    unawaited(_handle(fire));
  }

  Future<void> _handle(TriggerFire fire) async {
    final trigger = list.triggers.where((t) => t.id == fire.triggerId).firstOrNull;
    if (trigger == null) return;
    await _fire(trigger, fire);
  }

  /// The system nudged while Dart was not listening — or while it was,
  /// which is the same news either way. The ids the alarm stashed are the
  /// fires it noticed; the kind's own catch-up is its own business (and
  /// watches were just rebuilt if anything changed), so this claims what
  /// the system named and no more.
  Future<void> onNudged() async {
    final ids = await alarmPort.takeFired();
    if (ids.isEmpty) return;
    for (final id in ids) {
      final trigger =
          list.triggers.where((t) => t.id == id).firstOrNull;
      if (trigger == null) continue;
      await _fire(trigger, TriggerFire(trigger.id, "woken by the system clock"));
    }
    // The receiver held the process for these; they are dealt with now, one
    // way or the other — unless one is still running, in which case its turn
    // will release once it ends. Releasing here would stop the service
    // before the turn's own hold has registered, and a duplicate exact alarm
    // can deliver a nudge mid-turn.
    if (_runningIds.isEmpty) await alarmPort.doneFiring();
  }

  /// One fire of one trigger, whatever kind said it was due. The whole of
  /// what every source has in common, and the only place that runs a turn.
  Future<void> _fire(Trigger trigger, TriggerFire fire) async {
    // Claimed before the first await, not after: asking the platform whether
    // it can hold us is a round trip, and two watchers either side of it
    // would both find nothing running and both start a turn.
    if (!_runningIds.add(trigger.id)) return;
    var fireLate = false;
    try {
      fireLate = fire.late_;
      final kind = _kindOf(trigger);
      // A fire the platform will not hold is handed back to its alarm rather
      // than run — the kind knows whether there is one to hand back to.
      if (kind != null && await kind.defer(trigger)) return;
      kind?.ran(trigger);
      final result = await runner.run(trigger, fire.reason, await projects());
      await alarmPort.notify(
        title: nameOf(trigger),
        body: switch (result.outcome) {
          TriggerOutcome.done when result.snippet.isNotEmpty =>
            fireLate ? "Ran late.\n\n${result.snippet}" : result.snippet,
          TriggerOutcome.done => fireLate ? "Ran late. Finished." : "Finished.",
          TriggerOutcome.error =>
            fireLate ? "Ran late. The task failed." : "The task failed.",
          TriggerOutcome.aborted => "The task was stopped.",
        },
        chatId: result.chatId,
      );
      final now = clock.now();
      final next = kind?.nextFire(trigger, now);
      final fired = trigger.copyWith(lastFiredAt: now, clearNextFireAt: true);
      await list.replace(next == null ? fired : fired.copyWith(nextFireAt: next));
      // The replacement is what the kinds' watches rebuild on: the provider
      // listening to its own list re-enters reload — and so a repeating
      // trigger's next occurrence is watched by the new watch, not this one.
      await reload();
    } finally {
      _runningIds.remove(trigger.id);
    }
  }
}