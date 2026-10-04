import "dart:async";

import "package:clock/clock.dart";
import "package:flutter_test/flutter_test.dart";

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

/// The runs the manager asked for, and nothing else.
class StubRunner implements TriggerRuns {
  final firedIds = <String>[];
  final reasons = <String>[];

  /// Set when a test wants a run to hang, the way a real turn does.
  Completer<void>? gate;

  @override
  Future<TriggerRunResult> run(Trigger trigger, String reason, List<String> projects) async {
    firedIds.add(trigger.id);
    reasons.add(reason);
    if (gate != null) await gate!.future;
    return (chatId: "chat-${trigger.id}", outcome: TriggerOutcome.done, snippet: "done");
  }
}

TriggerManager manager(
  FakeList list,
  StubRunner runner,
  FakeReminderAlarms alarms, {
  List<TriggerKind>? kinds,
  required Clock clock,
}) =>
    TriggerManager(
      kinds: kinds ?? [ScheduleKind(alarms), TimerKind(alarms)],
      alarmPort: alarms,
      runner: runner,
      list: list,
      projects: () async => const [],
      clock: clock,
    );

void main() {
  late FakeList list;
  late StubRunner runner;
  late FakeReminderAlarms alarms;

  setUp(() {
    list = FakeList([]);
    runner = StubRunner();
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

    // Only the nudged id is in hand: the arm against the other would have
    // re-armed it for the future, but catch-up here is the ids' alone.
    list.triggers = [nudged, trigger(id: "other", nextFireAt: DateTime(2026, 9), code: 8)];
    alarms.fire("nudged");
    await mgr.onNudged();

    expect(runner.firedIds, ["nudged"]);
  });
}