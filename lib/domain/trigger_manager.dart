import "dart:async";

import "package:clock/clock.dart";
import "package:flutter/foundation.dart" show debugPrintStack, kDebugMode;

import "../core/log.dart" show logFailure;
import "reminder_alarms.dart";
import "prompt_library.dart";
import "models.dart" show CompletionKind;
import "trigger.dart";
import "trigger_kinds.dart";
import "trigger_runner.dart";

/// The seam the trigger tools reach, one per chat: the backend builds it
/// with the chat's own id, so the tools carry no chat id of their own — a
/// worker is withheld the registry outright, which is where a "whose chat"
/// question could not have an answer anyway.
abstract interface class TriggerRegistry {
  /// A fresh id (and request code where the source wants one), armed
  /// against now, in the chat this registry answers for. Answers what was
  /// stored, id and all. A [member] name this chat's project's library does
  /// not hold is refused with what was not found — the model can fix its
  /// own registration.
  Future<Trigger> register({
    required TriggerSource source,
    required String prompt,
    String? name,
    String? member,
  });

  /// This chat's own — what the tools list, and what may be removed.
  Future<List<Trigger>> own();

  Future<void> remove(String id);
}

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

  /// The projects that exist, asked only when a fire has to name a new
  /// chat's project — a chat-targeted fire resolves nothing in it.
  final Future<List<String>> Function() projects;
  final Clock clock;

  /// What a completion notification titles where the trigger carries no
  /// name. One wording, [Trigger.title]'s; there is no second copy.
  String nameOf(Trigger trigger) => trigger.title;

  StreamSubscription<void>? _nudges;
  final Map<TriggerKind, StreamSubscription<TriggerFire>> _watches = {};

  /// Triggers with a turn running. A second watcher arriving while one is
  /// under way finds the id here and stands down.
  final Set<String> _runningIds = {};

  /// The fires this generation of watches has delivered and not finished —
  /// one future to await, so a reload's caller settles what *its* watches
  /// opened with rather than only starting it. Reset when the watches are
  /// rebuilt: a previous generation's outstanding turn is the single-flight
  /// set's business (a later watcher stands down against it), not this
  /// reload's to wait behind. Contained all the same: the provider's own
  /// listen calls reload unawaited, so a run that hangs hangs only the
  /// drain that opened it, and nothing the user typed waits on it.
  Future<void> _delivered = Future.value();

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
  TriggerKind? _kindOf(Trigger trigger) {
    for (final kind in kinds) {
      if (kind.matches(trigger)) return kind;
    }
    return null;
  }

  /// The list changed: rebuild the kinds' watches — each diffing its own
  /// alarms, catching up its own past-due fires, and aiming its own timer —
  /// then release the launch's hold. [awaitStarted] is what keeps the
  /// release after whatever the watches report: a pump would cover the
  /// microtasks and nothing else, and a watch still parked on a MethodChain
  /// round trip's catch-up would then be released under.
  ///
  /// The release at the end is for the launch this is the first call of: an
  /// alarm that woke the process holds it, and by here whatever it woke us
  /// for has run. Every other caller is an edit, where there is no hold to
  /// release and this says so to a platform that already agrees.
  ///
  /// It is a no-op while a fire's turn is running: a fire stamps the trigger
  /// list mid-turn, which re-enters here, and releasing then would drop the
  /// receiver's hold before the turn's own foreground-service hold has
  /// registered. See "Waking for a reminder" in `android/AGENTS.md`.
  Future<void> reload() async {
    final started = <Future<void>>[];
    for (final sub in _watches.values) {
      unawaited(sub.cancel());
    }
    _watches.clear();
    // This generation's drain starts here: what the last one opened and
    // never finished is not waited on a second time (see _delivered).
    _delivered = Future.value();
    for (final kind in kinds) {
      final ofKind = [
        for (final t in list.triggers)
          if (kind.matches(t) && kind.armed(t)) t,
      ];
      final watch = kind.watch(ofKind, clock);
      started.add(watch.started);
      _watches[kind] = watch.stream.listen(_onFire);
    }
    for (final future in started) {
      await future;
    }
    // The catch-up fires settled to their claims — the claim is the
    // synchronous head of every fire path, so the one pump the deliveries
    // need (a non-sync controller queues them) is all the window this
    // closes. A run hanging beyond that is what the single-flight set and
    // its own list stamp answer for; awaiting one here would hang every
    // edit behind it.
    await _delivered;
    await Future<void>.delayed(Duration.zero);
    if (_runningIds.isEmpty) await alarmPort.doneFiring();
  }

  /// A watch's stream delivers; the fire's work runs from here, chained so
  /// a settle below has the one future everything outstanding hangs off.
  /// The fire's own failures are contained to it — an errored link left
  /// standing would skip every fire chained after it for the life of the
  /// generation, so the chain never carries an error and each fire logs its
  /// own.
  void _onFire(TriggerFire fire) {
    _delivered = _delivered.then((_) async {
      try {
        await _fire(fire);
      } catch (e, st) {
        logFailure("triggers", "fire of ${fire.triggerId} failed", e);
        if (kDebugMode) debugPrintStack(stackTrace: st, maxFrames: 12);
      }
    });
  }

  /// The system nudged while Dart was not listening — or while it was,
  /// which is the same news either way. The ids the alarm stashed are the
  /// fires it noticed; the kind's own catch-up is its own business (and
  /// watches were just rebuilt if anything changed), so this claims what
  /// the system named and no more. The reason is the kind's — the same
  /// words a timer-spotted fire would carry — for the same fire to say the
  /// same thing about itself whichever watcher won the race.
  ///
  /// The ids are the system's say-so, not the list's: an alarm already
  /// delivered before the trigger fired (a duplicate exact alarm) or before
  /// it was switched off is a message about a fire that is no longer armed,
  /// so a nudge is held to the same gate the watch itself answers — enabled
  /// and still to come. The old scheduler's `dueBy` was this gate; it rides
  /// here now that the kinds own the arithmetic.
  Future<void> onNudged() async {
    final ids = await alarmPort.takeFired();
    if (ids.isEmpty) return;
    for (final id in ids) {
      final trigger = list.triggers.where((t) => t.id == id).firstOrNull;
      if (trigger == null || !_due(trigger, clock.now())) continue;
      final reason = _kindOf(trigger)?.reasonOf(trigger) ?? "the clock reached its time";
      await _fire(TriggerFire(trigger.id, reason));
    }
    // The receiver held the process for these; they are dealt with now, one
    // way or the other — unless one is still running, in which case its turn
    // will release once it ends. Releasing here would stop the service
    // before the turn's own hold has registered, and a duplicate exact alarm
    // can deliver a nudge mid-turn.
    if (_runningIds.isEmpty) await alarmPort.doneFiring();
  }

  /// Whether a trigger is still armed against a moment that has arrived —
  /// the one gate between a watcher's say-so and a run. A fired one-shot
  /// (`nextFireAt` cleared) and a switched-off trigger both fail it, which
  /// is what keeps a duplicate nudge from running a turn twice.
  bool _due(Trigger trigger, DateTime now) =>
      trigger.enabled &&
      trigger.nextFireAt != null &&
      !now.isBefore(trigger.nextFireAt!);

  /// One fire of one trigger, whatever kind said it was due. The whole of
  /// what every source has in common, and the only place that runs a turn
  /// — and the only place that answers for one: the notification, the
  /// stamp, and the disarm of a trigger whose target has gone all land
  /// here, where the copy being replaced is the one the fire was decided
  /// on.
  Future<void> _fire(TriggerFire fire) async {
    final trigger =
        list.triggers.where((t) => t.id == fire.triggerId).firstOrNull;
    if (trigger == null) return;
    // Claimed before the first await, not after: asking the platform whether
    // it can hold us is a round trip, and two watchers either side of it
    // would both find nothing running and both start a turn.
    if (!_runningIds.add(trigger.id)) return;
    final kind = _kindOf(trigger);
    try {
      // A fire the platform will not hold is handed back to its alarm rather
      // than run — the kind knows whether there is one to hand back to.
      if (kind != null && await kind.defer(trigger)) return;
      kind?.ran(trigger);
      final result =
          await runner.run(trigger, fire.reason, await projects());
      if (result.targetGone) {
        // The chat a trigger pointed at has been deleted (a swept temp chat
        // among them): the trigger is disarmed here rather than left armed
        // against a chat that no longer exists — and rather than re-pointed
        // at some other conversation. The runner words the notification; the
        // stamp here is the disarm landing, from the copy this fire
        // decided on, so nothing re-arms what it just switched off.
        await list.replace(trigger.copyWith(
            enabled: false, clearNextFireAt: true));
        return;
      }
      final now = clock.now();
      // How late the fire was is said once, from the one nextFireAt the
      // fire was due at — the nudge's and the catch-up's the same, no
      // watcher's race deciding the wording.
      final late =
          now.difference(trigger.nextFireAt ?? now) > ClockKind.late;
      await alarmPort.notify(
        title: nameOf(trigger),
        body: switch (result.outcome) {
          TriggerOutcome.done when result.snippet.isNotEmpty =>
            late ? "Ran late.\n\n${result.snippet}" : result.snippet,
          TriggerOutcome.done => late ? "Ran late. Finished." : "Finished.",
          TriggerOutcome.error =>
            late ? "Ran late. The task failed." : "The task failed.",
          TriggerOutcome.aborted => "The task was stopped.",
        },
        chatId: result.chatId,
      );
      final next = kind?.nextFire(trigger, now);
      // The stamp is the runner's — it went in before the turn ran (that is
      // the field's contract) — so this replacement is a delta on the list's
      // current record, not a write from the fire's own stale copy: it
      // advances what the watches build on (`nextFireAt`) and carries
      // forward whatever the turn path stamped.
      final current =
          list.triggers.where((t) => t.id == trigger.id).firstOrNull ?? trigger;
      final fired = current.copyWith(clearNextFireAt: true);
      await list.replace(next == null ? fired : fired.copyWith(nextFireAt: next));
    } finally {
      _runningIds.remove(trigger.id);
    }
  }
}

/// The chat-scoped face the agent's turn is handed: one chat's registry,
/// over the whole list. The tools ask and answer in this chat's vocabulary;
/// the list stays one, and the provider's reload is what watches a
/// registration the moment it lands.
///
/// The project comes with the chat — it is what the fire's mention resolves
/// against and what a [register] validates its member against. Validation
/// rides the same library the composing turn was handed, so a member
/// deleted mid-conversation is refused by the snapshot the room itself
/// reads; a *stored* member later deleted is not re-checked (a stored
/// record has nothing to consult every launch) and degrades at fire time to
/// the room's own prose rule.
class ChatTriggerRegistry implements TriggerRegistry {
  ChatTriggerRegistry(this._owner, this.chatId, this.project);

  final TriggerRegistryOwner _owner;
  final String chatId;
  final String? project;

  @override
  Future<Trigger> register(
      {required TriggerSource source,
      required String prompt,
      String? name,
      String? member}) async {
    final library = _owner.libraryFor(project);
    if (member != null && library?.find(CompletionKind.agent, member) == null) {
      throw ArgumentError.value(
          member, "member", "no agent named $member in this project");
    }
    return _owner.registerFor(chatId,
        source: source, prompt: prompt, name: name, member: member);
  }

  @override
  Future<List<Trigger>> own() async => [
        for (final t in await _owner.triggers())
          if (t.byAgent && t.chatId == chatId) t,
      ];

  @override
  Future<void> remove(String id) => _owner.remove(id);
}

/// What a [ChatTriggerRegistry] acts through — the provider's notifier, or
/// a test's stand-in. Async throughout: the list is where one turn's
/// registration meets another's fire, and no read here is worth a
/// synchronisation the provider has to invent.
abstract interface class TriggerRegistryOwner {
  Future<List<Trigger>> triggers();
  Future<Trigger> registerFor(String chatId,
      {required TriggerSource source, required String prompt, String? name, String? member});

  /// The named project's libraries — what a registration's member is
  /// checked against, and the list the fire's own library rides. Null is
  /// the default project.
  PromptLibrary? libraryFor(String? project);
  Future<void> remove(String id);
}

/// What the backend holds: a registry per chat, built where the turn asks
/// for one — one function rather than an adapter class per layer.
typedef TriggerRegistryFactory = TriggerRegistry Function(
    String chatId, String? project);