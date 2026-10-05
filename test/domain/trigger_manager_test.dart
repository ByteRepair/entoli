import "dart:async";

import "package:clock/clock.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/file_watches.dart";
import "package:agent_chat/domain/reminder_alarms.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/trigger_kinds.dart";
import "package:agent_chat/domain/trigger_manager.dart";
import "package:agent_chat/domain/trigger_runner.dart";

import "../fakes.dart";

/// After every trigger fire date the suite seeds, so a trigger due "today" is
/// due under it. Pinned rather than the wall clock so the suite does not rot
/// against the calendar.
final _now = Clock.fixed(DateTime(2026, 8, 23, 9));

/// The list, held in memory — the manager reads and writes it through this,
/// exactly as it does through the provider in the app.
class FakeList implements TriggerList {
  FakeList(this.triggers);

  @override
  List<Trigger> triggers;

  @override
  Future<void> write(List<Trigger> triggers) async {
    this.triggers = triggers;
    written.add(triggers);
  }

  @override
  Future<void> replace(Trigger trigger) async {
    triggers = [for (final t in triggers) if (t.id == trigger.id) trigger else t];
    written.add(triggers);
  }

  final written = <List<Trigger>>[];
}

TriggerManager manager(
  FakeList list,
  StubRuns runner,
  FakeReminderAlarms alarms, {
  List<TriggerKind>? kinds,
  required Clock clock,
}) =>
    TriggerManager(
      kinds: kinds ??
          [
            ClockKind(alarms, matchOf: (t) => t.source is ScheduleSource),
            ClockKind(alarms, matchOf: (t) => t.source is TimerSource),
          ],
      alarmPort: alarms,
      runner: runner,
      list: list,
      projects: () async => const [],
      clock: clock,
    );

void main() {
  late FakeList list;
  late StubRuns runner;
  late FakeReminderAlarms alarms;

  setUp(() {
    list = FakeList([]);
    runner = StubRuns()
      ..nowOf = () {
        return DateTime(2026, 8, 23, 9);
      }
      // The stamp goes through the list's replace, as the real runner's
      // onTriggerFired does — but bound lazily, since the test rewires
      // list.triggers after setUp.
      ..stampThrough = (trigger) => list.replace(trigger);
    alarms = FakeReminderAlarms();
  });

  Trigger trigger({
    String id = "r1",
    DateTime? at,
    ScheduleRepeat repeat = ScheduleRepeat.off,
    TriggerSource? source,
    bool enabled = true,
    DateTime? nextFireAt,
    int code = 1,
  }) =>
      Trigger(
        id: id,
        name: id,
        prompt: "p",
        source: source ?? ScheduleSource(at: at ?? DateTime(2026, 8, 22, 9), repeat: repeat),
        enabled: enabled,
        nextFireAt: nextFireAt,
        requestCode: code,
      );

  test("catch-up fires what is overdue once and disarms the one-shot", () async {
    list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 22, 9))];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(runner.firedIds, ["r1"]);
    final after = list.triggers.single;
    expect(after.lastFiredAt, isNotNull);
    // A one-shot that fired has nothing armed — not a time it would re-fire at.
    expect(after.nextFireAt, isNull);
  });

  test("a repeating trigger moves to its next occurrence", () async {
    list.triggers = [
      trigger(
        at: DateTime(2026, 8, 22, 9),
        repeat: ScheduleRepeat.daily,
        nextFireAt: DateTime(2026, 8, 22, 9),
      ),
    ];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(list.triggers.single.nextFireAt!.isAfter(DateTime(2026, 8, 23)), isTrue);
  });

  test("a fire well past its time says so in the notification", () async {
    list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 1, 9))];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(alarms.posted.single.body, contains("late"));
    expect(alarms.posted.single.chatId, "chat-r1");
  });

  test("a fire on time does not", () async {
    final onTime = _now.now().subtract(const Duration(seconds: 5));
    list.triggers = [
      trigger(nextFireAt: onTime),
    ];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(alarms.posted.single.body, isNot(contains("late")));
  });

  test("a disabled trigger never fires", () async {
    list.triggers = [trigger(enabled: false, nextFireAt: DateTime(2000))];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(runner.firedIds, isEmpty);
    expect(alarms.posted, isEmpty);
  });

  test("the timer kind arms and fires like the schedule kind", () async {
    list.triggers = [
      trigger(
        id: "t1",
        source: TimerSource(
            duration: const Duration(minutes: 30), registeredAt: DateTime(2026, 8, 22, 8)),
        nextFireAt: DateTime(2026, 8, 22, 8, 30),
      ),
    ];
    await manager(list, runner, alarms, clock: _now).reload();

    expect(runner.firedIds, ["t1"]);
  });

  test("a second trigger while a run is under way stands down", () async {
    list.triggers = [trigger(nextFireAt: DateTime(2000))];
    runner.gate = Completer<void>();
    final mgr = manager(list, runner, alarms, clock: _now);

    final first = mgr.reload();
    // Far enough in for the run to have started: asking the platform for the
    // hold comes first, and it is a round trip.
    await pumpEventQueue();
    // While the first run hangs, another watcher arrives for the same id.
    await mgr.reload();
    expect(runner.firedIds, ["r1"]);
    runner.gate!.complete();
    await first;
    expect(runner.firedIds, ["r1"]);
  });

  // Releasing mid-turn stops the service before the turn's own hold registers,
  // killing the process under it — so doneFiring is a no-op while one runs.
  test("a reload while a fire's turn is running does not release the hold", () async {
    list.triggers = [trigger(nextFireAt: DateTime(2000))];
    runner.gate = Completer<void>();
    final mgr = manager(list, runner, alarms, clock: _now);

    final first = mgr.reload();
    await pumpEventQueue();
    // The re-entrant reload a fire's own stamp triggers, mid-turn.
    await mgr.reload();
    expect(alarms.released, 0);
    runner.gate!.complete();
    await first;
  });

  test("a nudge while a fire's turn is running does not release the hold", () async {
    list.triggers = [trigger(nextFireAt: DateTime(2000))];
    runner.gate = Completer<void>();
    final mgr = manager(list, runner, alarms, clock: _now);

    final first = mgr.reload();
    await pumpEventQueue();
    // A duplicate exact alarm delivers another nudge for the running fire.
    alarms.fire("r1");
    await mgr.onNudged();
    expect(alarms.released, 0);
    runner.gate!.complete();
    await first;
  });

  test("sync arms every enabled trigger and cancels the dropped ones", () async {
    // Before the triggers' fire time, so catch-up leaves them armed: this
    // tests the alarm diff, not firing.
    final before = Clock.fixed(DateTime(2026, 7, 1));
    final kept = trigger(id: "kept", nextFireAt: DateTime(2026, 9), code: 3);
    await list.write([kept, trigger(id: "dropped", nextFireAt: DateTime(2026, 9), code: 4)]);
    final mgr = manager(list, runner, alarms, clock: before);
    await mgr.reload();
    expect(alarms.scheduled.keys.toSet(), {3, 4});

    await list.write([kept]);
    await mgr.reload();

    expect(alarms.cancelled, [4]);
    expect(alarms.scheduled.keys, [3]);
  });

  group("the hold a turn needs", () {
    test("a fire the platform will not hold is handed back to the alarm", () async {
      alarms.canHold = false;
      list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 22, 9), code: 5)];
      await manager(list, runner, alarms, clock: _now).reload();

      expect(runner.firedIds, isEmpty);
      // Re-armed for the time it was already due, which the system delivers at
      // once — and its receiver is what may hold the process.
      expect(alarms.scheduled[5], DateTime(2026, 8, 22, 9));
      expect(list.triggers.single.lastFiredAt, isNull);
    });

    test("the fire that comes back runs, held", () async {
      alarms.canHold = false;
      list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 22, 9), code: 5)];
      final mgr = manager(list, runner, alarms, clock: _now);
      await mgr.reload();

      alarms.canHold = true;
      alarms.fire("r1");
      await mgr.onNudged();

      expect(runner.firedIds, ["r1"]);
    });

    test("a hold refused twice runs it anyway rather than never", () async {
      alarms.canHold = false;
      list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 22, 9), code: 5)];
      final mgr = manager(list, runner, alarms, clock: _now);
      await mgr.reload();
      await mgr.reload();

      expect(runner.firedIds, ["r1"]);
    });

    test("a platform with no alarms runs it where it is", () async {
      final none = FakeReminderAlarms(available: false)..canHold = false;
      list.triggers = [trigger(nextFireAt: DateTime(2026, 8, 22, 9))];
      await manager(list, runner, none, clock: _now).reload();

      expect(runner.firedIds, ["r1"]);
    });

    test("the wake is released once the fires are dealt with", () async {
      list.triggers = [trigger(nextFireAt: DateTime(2000))];
      final mgr = manager(list, runner, alarms, clock: _now);
      alarms.fire("r1");
      await mgr.onNudged();

      expect(runner.firedIds, ["r1"]);
      expect(alarms.released, 1);
    });

    test("a launch with nothing due releases it too", () async {
      await manager(list, runner, alarms, clock: _now).reload();

      expect(alarms.released, 1);
    });
  });

  test("the nudge path claims only what the system noticed", () async {
    final nudged = trigger(id: "nudged", nextFireAt: DateTime(2000), code: 7);
    await list.write([
      nudged,
      trigger(id: "other", nextFireAt: DateTime(2000), code: 8),
    ]);
    final mgr = manager(list, runner, alarms, clock: _now);
    await mgr.reload();
    // Settle the catch-up the first reload fires; the assertion is about the
    // nudge below.
    runner.firedIds.clear();

    // Only the nudged id is claimed: the alarm stashed one, and the other
    // trigger — no longer overdue — is not fired by the nudge's arrival.
    list.triggers = [nudged, trigger(id: "other", nextFireAt: DateTime(2026, 9), code: 8)];
    alarms.fire("nudged");
    await mgr.onNudged();

    expect(runner.firedIds, ["nudged"]);
  });

  test("a nudged fire carries the kind's own reason, not the watcher's",
      () async {
    // Not armed at reload — the nudge is the news, not catch-up.
    list.triggers = [
      Trigger(
        id: "late-r",
        name: "n",
        prompt: "p",
        source: ScheduleSource(at: DateTime(2026, 8, 1, 9)),
      ),
    ];
    final mgr = manager(list, runner, alarms, clock: _now);
    await mgr.reload();
    expect(runner.firedIds, isEmpty);

    // Armed from the nudge's side, already overdue: the system noticed
    // while the process was away.
    list.triggers = [
      Trigger(
        id: "late-r",
        name: "n",
        prompt: "p",
        source: ScheduleSource(at: DateTime(2026, 8, 1, 9)),
        nextFireAt: DateTime(2026, 8, 1, 9),
      ),
    ];
    alarms.fire("late-r");
    await mgr.onNudged();

    // The nudge asked the kind, so the reason is the schedule's own words —
    // what was set, the same a timer-spotted fire carries — and the
    // lateness is the manager's one computation: "Ran late." in the
    // notification, for a nudge-late fire and not only a caught-up one.
    expect(runner.reasons.single, contains("1 Aug"));
    expect(runner.reasons.single, contains("9:00 AM"));
    expect(alarms.posted.single.body, contains("late"));
  });

  group("with the file kind registered", () {
    // See `trigger_file_kind_test.dart` for the kind in isolation; here
    // the registry — a FileKind over a fake watcher — reaches a fire
    // through the whole manager, and the fire is stamped like any other.
    late RecordingFileWatches watches;

    setUp(() {
      watches = RecordingFileWatches();
    });

    test("a file fire runs the trigger and stamps it, and re-arms nothing",
        () async {
      list.triggers = [
        trigger(id: "f1", source: FileSource(paths: const ["notes/"])),
      ];
      final mgr = TriggerManager(
        kinds: [
          FileKind(
              fileWatches: watches,
              resolve: (t, path) async => "/ws/$path"),
        ],
        alarmPort: alarms,
        runner: runner,
        list: list,
        projects: () async => const [],
        clock: _now,
      );
      final done = mgr.reload();
      await pumpEventQueue();
      expect(watches.roots, ["/ws/notes/"]);

      watches.push("/ws/notes/build.log", FileEvent.change);
      await pumpEventQueue();
      await done;

      expect(runner.firedIds, ["f1"]);
      expect(runner.reasons.single, contains("build.log"));
      final after = list.triggers.single;
      expect(after.lastFiredAt, isNotNull);
      // A file source is never on the clock.
      expect(after.nextFireAt, isNull);
    });

    test("a target chat that has gone disarms, once, with no completion",
        () async {
      list.triggers = [
        Trigger(
          id: "g1",
          name: "n",
          prompt: "p",
          source: ScheduleSource(at: DateTime(2026, 8, 22, 9), repeat: ScheduleRepeat.daily),
          chatId: "chat-gone",
          nextFireAt: DateTime(2026, 8, 22, 9),
        ),
      ];
      // The runner answers as the real one does to a deleted chat.
      final runs = _GoneTargetRuns();
      final mgr = TriggerManager(
        kinds: [
          ClockKind(alarms, matchOf: (t) => t.source is ScheduleSource),
        ],
        alarmPort: alarms,
        runner: runs,
        list: list,
        projects: () async => const [],
        clock: _now,
      );
      await mgr.reload();

      // The disarm is the fire's own stamp: disabled, nothing armed — and
      // not silently reverted to armed the way a stale-copy stamp would.
      final after = list.triggers.single;
      expect(after.enabled, isFalse);
      expect(after.nextFireAt, isNull);
      // One notification — the runner's worded one — not a second
      // "The task failed." beside it.
      expect(runs.posts.single.body, contains("no longer exists"));
      expect(alarms.posted, isEmpty);
      // The runner was asked once — and answered targetGone; the disarm is
      // the manager's, from the fire's own copy.
      expect(runs.firedIds, ["g1"]);
    });
  });
}

/// The file system's push, for the manager's file-kind group; the file-kind
/// tests drive their own copy in [FakeFileWatches]. Same shape, second name
/// only because this one is in a manager test's scope.
class RecordingFileWatches implements FileWatches {
  final events = StreamController<FileWatchEvent>.broadcast();
  final roots = <String>[];

  @override
  bool get available => true;

  @override
  Stream<FileWatchEvent> watch(String root) {
    roots.add(root);
    return events.stream;
  }

  void push(String path, FileEvent kind) =>
      events.add(FileWatchEvent(path: path, kind: kind));
}

/// A [TriggerRuns] that reports the target gone but posts as the real
/// runner does — the worded notification being the runner's, before the
/// manager's stamp.
class _GoneTargetRuns implements TriggerRuns {
  final firedIds = <String>[];
  final posts =
      <({String title, String body, String? chatId, String channel})>[];

  @override
  Future<TriggerRunResult> run(Trigger trigger, String reason, List<String> projects) async {
    firedIds.add(trigger.id);
    posts.add((title: trigger.title, body: "The chat this trigger runs in no "
        "longer exists, so it was switched off.", chatId: null,
        channel: ReminderAlarms.defaultChannel));
    return (chatId: trigger.chatId ?? "", outcome: TriggerOutcome.error,
        snippet: "", targetGone: true);
  }
}