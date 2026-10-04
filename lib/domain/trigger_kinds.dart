import "dart:async";

import "package:clock/clock.dart";

import "file_watches.dart";
import "reminder_alarms.dart";
import "trigger.dart";

/// What a kind reports to the manager — which trigger fired, and the words
/// the fire says for itself. The reason rides in the prompt the runner sends
/// rather than in a side channel, so the log says why a turn started.
class TriggerFire {
  const TriggerFire(this.triggerId, this.reason, {this.lateFire = false});

  final String triggerId;
  final String reason;

  /// Whether the fire arrived well past its time — a trigger missed while
  /// the process was dead, caught up at launch. The completion's wording
  /// says so; an exact alarm, arriving within seconds, does not.
  final bool lateFire;
}

/// The behaviour of one source kind: what watches the source becoming true,
/// and what to call when it is. One registration in [TriggerManager]'s
/// registry; nothing in the manager switches on kind.
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

  /// What to watch. Answers a stream that covers the triggers given, which
  /// are exactly [matches] and [armed] over one snapshot of the list: the
  /// manager swaps the list under one subscription per reload rather than
  /// one per trigger. A clock kind's stream carries its own catch-up of
  /// what passed while nothing was running and its own timer; a file
  /// kind's, its watchers, each debounced.
  ///
  /// The stream is controller-backed rather than a generator: a watcher
  /// torn down on a list change has to stop *now*, whatever it is parked
  /// on — a countdown hours out being a generator's undoing. One listen, so
  /// a single-subscription controller is right.
  Stream<TriggerFire> watch(List<Trigger> triggers, Clock clock);

  /// Hand a fire back rather than run it, where the platform will not hold
  /// the process for the turn — answered before the runner is called, once
  /// per fire. False where there is nothing to hand back to: a desktop has
  /// no alarm, a file source no clock, and running it merely killable is
  /// where every such platform already is.
  Future<bool> defer(Trigger trigger);

  /// The deferred fire ran (or was given up on); it may be handed back
  /// again next time.
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
/// The timer is this class's own rather than the manager's because it is
/// the "what to check" of a clock source: it fires on time whether or not
/// anyone is looking, and off screen on Android the only moment the process
/// may take the hold that keeps it alive is inside the broadcast its own
/// alarm delivers — so a fire nothing can hold is re-armed for the time it
/// was already due, which [ReminderAlarms.schedule] delivers at once: the
/// receiver holds the process and the fire comes back through the manager
/// seconds later, held. A watch is torn down on every list change, which is
/// exactly when the diff has to run — one place, not two kept level by
/// hand.
abstract class ClockKind extends TriggerKind {
  ClockKind(this.alarms);

  /// The alarm port's scheduling half. Notify is not here: the manager is
  /// where a fire answers for itself, and a kind has no conversation to
  /// answer about.
  final ReminderAlarms alarms;

  /// What is currently registered with the system, by request code — the
  /// diff between this and the watch's snapshot is what _diffAlarms
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

  TriggerFire _fireOf(Trigger trigger, DateTime now, String reason) =>
      TriggerFire(trigger.id, reason,
          lateFire: now.difference(trigger.nextFireAt!) > late);

  @override
  bool armed(Trigger trigger) =>
      trigger.enabled && trigger.nextFireAt != null;

  @override
  DateTime? nextFire(Trigger trigger, DateTime after) =>
      trigger.source.nextAfter(after);

  @override
  void ran(Trigger trigger) => _deferred.remove(trigger.id);

  @override
  Stream<TriggerFire> watch(List<Trigger> triggers, Clock clock) {
    late StreamController<TriggerFire> controller;
    Timer? timer;

    void aim() {
      timer?.cancel();
      DateTime? nearest;
      final now = clock.now();
      for (final trigger in triggers) {
        final at = trigger.nextFireAt;
        if (at != null && at.isAfter(now) &&
            (nearest == null || at.isBefore(nearest))) {
          nearest = at;
        }
      }
      if (nearest == null) return;
      final wait = nearest.difference(clock.now());
      timer = Timer(wait.isNegative ? Duration.zero : wait, () {
        final now = clock.now();
        // Whatever has passed fires; a repeating trigger's stamp lands only
        // once its turn has run, so the watch is rebuilt underneath this
        // timer and this one is cancelled with it.
        for (final trigger in triggers) {
          final at = trigger.nextFireAt;
          if (at != null && !at.isAfter(now)) {
            controller.add(_fireOf(trigger, now, reasonOf(trigger)));
          }
        }
        aim();
      });
    }

    Future<void> start() async {
      // The alarm diff first: the boot receiver re-arms what it reads, and
      // whatever the list changed is said to the system here.
      await _diffAlarms(triggers);
      // Catch-up: what passed while nothing was running fires now.
      final now = clock.now();
      for (final trigger in triggers) {
        final at = trigger.nextFireAt;
        if (at != null && !at.isAfter(now)) {
          controller.add(_fireOf(trigger, now, reasonOf(trigger)));
        }
      }
      aim();
    }

    controller = StreamController<TriggerFire>(
      onListen: () {
        unawaited(start());
      },
      onPause: () => timer?.cancel(),
      onResume: aim,
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }

  /// What the fire says set it off: the schedule or its next recurrence, in
  /// the words the user set it with.
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
  bool armed(Trigger trigger) => matches(trigger) && super.armed(trigger);

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
  bool armed(Trigger trigger) => matches(trigger) && super.armed(trigger);

  @override
  String get label => "Timer";
}

/// The file source's kind: watchers over resolved roots, debounced. A file
/// trigger is never on the clock — nothing is handed to a system scheduler,
/// and a fire missed while the process was not running is not re-delivered
/// by anything. On Android a frozen process holds its inotify events until
/// it thaws; the app closed drops them, which the settings page says.
class FileKind extends TriggerKind {
  FileKind({required this.fileWatches, this.resolve});

  /// The platform's watcher, or the unavailable one: a browser is where
  /// this kind has nothing to watch with, the way the alarms port is what
  /// the clock kinds' answer rides on.
  final FileWatches fileWatches;

  /// Resolves a stored path to a watchable root, through the same rules the
  /// file tools read — `project:`/`chat:` prefixes, relative paths in the
  /// chat's workspace, `~` expanded. Set by whoever builds the kind, since
  /// where the workspaces are is the builder's to say.
  final Future<String> Function(Trigger trigger, String path)? resolve;

  @override
  bool matches(Trigger trigger) => trigger.source is FileSource;

  @override
  bool armed(Trigger trigger) {
    final source = trigger.source;
    return trigger.enabled &&
        source is FileSource &&
        source.paths.isNotEmpty &&
        resolve != null;
  }

  @override
  DateTime? nextFire(Trigger trigger, DateTime after) => null;

  @override
  Future<bool> defer(Trigger trigger) async => false;

  @override
  void ran(Trigger trigger) {}

  @override
  String get label => "Files";

  @override
  Stream<TriggerFire> watch(List<Trigger> triggers, Clock clock) {
    late StreamController<TriggerFire> controller;
    final subscriptions = <StreamSubscription<FileWatchEvent>>[];

    /// What each trigger fired last, for the cooldown: a burst of writes to
    /// the watched path is one turn rather than one a line.
    final seen = <String, DateTime>{};

    Future<void> start() async {
      // One root is one watcher, however many triggers name it: a fan of
      // triggers over the same workspace is one inotify subscription.
      final byRoot = <String, List<(Trigger, FileSource)>>{};
      for (final trigger in triggers) {
        final source = trigger.source as FileSource;
        for (final path in source.paths) {
          final root = await resolve!(trigger, path);
          (byRoot[root] ??= []).add((trigger, source));
        }
      }
      for (final entry in byRoot.entries) {
        final pairs = entry.value;
        final sub = fileWatches.watch(entry.key).listen(
              (event) {
                for (final (trigger, source) in pairs) {
                  final fire = _fireFor(event, trigger, source, clock, seen);
                  if (fire != null) controller.add(fire);
                }
              },
              onError: (Object _) {
                // A watcher over a removed directory is silence; the next
                // registration rebuilds what the list still asks for.
              },
            );
        subscriptions.add(sub);
      }
    }

    controller = StreamController<TriggerFire>(
      onListen: () {
        unawaited(start());
      },
      onCancel: () async {
        for (final sub in subscriptions) {
          await sub.cancel();
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  /// Whether the event is one this trigger asks for, and whether its
  /// cooldown lets the answer be yes. The event is matched by *what* fired
  /// (create/change/delete/move) and the trigger by *where* — its paths are
  /// roots, and anything under one is in its reach.
  TriggerFire? _fireFor(
      FileWatchEvent event, Trigger trigger, FileSource source,
      Clock clock, Map<String, DateTime> seen) {
    if (!_eventMatches(event.kind, source.events)) return null;
    final last = seen[trigger.id];
    final now = clock.now();
    if (last != null && now.difference(last) < source.cooldown) return null;
    seen[trigger.id] = now;
    return TriggerFire(trigger.id, "file ${event.path} changed");
  }

  static bool _eventMatches(FileEventKind kind, Set<FileEvent> events) =>
      events.any((e) => e.watchKind == kind.name);
}