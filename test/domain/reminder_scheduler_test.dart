import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/reminder_runner.dart";
import "package:agent_chat/domain/reminder_scheduler.dart";

import "../fakes.dart";

/// The list, held in memory — the scheduler reads and writes it through this,
/// exactly as it does through the provider in the app.
class FakeList implements ReminderList {
  FakeList(this.reminders);

  @override
  List<Reminder> reminders;

  @override
  Future<void> write(List<Reminder> reminders) async {
    this.reminders = reminders;
    written.add(reminders);
  }

  @override
  Future<void> replace(Reminder reminder) async {
    reminders = [for (final r in reminders) if (r.id == reminder.id) reminder else r];
    written.add(reminders);
  }

  final written = <List<Reminder>>[];
}

/// The runs the scheduler asked for, and nothing else.
class StubRunner implements ReminderRuns {
  final firedIds = <String>[];

  /// Set when a test wants a run to hang, the way a real turn does.
  Completer<void>? gate;

  @override
  Future<ReminderRunResult> run(Reminder reminder, List<String> projects) async {
    firedIds.add(reminder.id);
    if (gate != null) await gate!.future;
    return (chatId: "chat-${reminder.id}", outcome: ReminderOutcome.done, snippet: "done");
  }
}

ReminderScheduler scheduler(FakeList list, StubRunner runner, FakeReminderAlarms alarms) =>
    ReminderScheduler(
      alarms: alarms,
      runner: runner,
      list: list,
      projects: () async => const [],
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

  Reminder reminder({
    String id = "r1",
    DateTime? at,
    ReminderRepeat repeat = ReminderRepeat.off,
    bool enabled = true,
    DateTime? nextFireAt,
    int code = 1,
  }) =>
      Reminder(
        id: id,
        name: id,
        prompt: "p",
        at: at ?? DateTime(2026, 8, 22, 9),
        repeat: repeat,
        enabled: enabled,
        nextFireAt: nextFireAt,
        requestCode: code,
      );

  test("catch-up fires what is overdue once and disarms the one-shot", () async {
    list.reminders = [reminder(nextFireAt: DateTime(2026, 8, 22, 9))];
    await scheduler(list, runner, alarms).catchUp();

    expect(runner.firedIds, ["r1"]);
    final after = list.reminders.single;
    expect(after.lastFiredAt, isNotNull);
    // A one-shot that fired has nothing armed — not a time it would re-fire at.
    expect(after.nextFireAt, isNull);
  });

  test("a repeating reminder moves to its next occurrence", () async {
    list.reminders = [
      reminder(
        at: DateTime(2026, 8, 22, 9),
        repeat: ReminderRepeat.daily,
        nextFireAt: DateTime(2026, 8, 22, 9),
      ),
    ];
    await scheduler(list, runner, alarms).catchUp();

    expect(list.reminders.single.nextFireAt!.isAfter(DateTime(2026, 8, 23)), isTrue);
  });

  test("a fire well past its time says so in the notification", () async {
    list.reminders = [reminder(nextFireAt: DateTime(2026, 8, 1, 9))];
    await scheduler(list, runner, alarms).catchUp();

    expect(alarms.posted.single.body, contains("late"));
    expect(alarms.posted.single.chatId, "chat-r1");
  });

  test("a fire on time does not", () async {
    list.reminders = [
      reminder(nextFireAt: DateTime.now().subtract(const Duration(seconds: 5))),
    ];
    await scheduler(list, runner, alarms).catchUp();

    expect(alarms.posted.single.body, isNot(contains("late")));
  });

  test("a disabled reminder never fires", () async {
    list.reminders = [reminder(enabled: false, nextFireAt: DateTime(2000))];
    await scheduler(list, runner, alarms).catchUp();

    expect(runner.firedIds, isEmpty);
    expect(alarms.posted, isEmpty);
  });

  test("a second trigger while a run is under way stands down", () async {
    list.reminders = [reminder(nextFireAt: DateTime(2000))];
    runner.gate = Completer<void>();
    final sched = scheduler(list, runner, alarms);

    final first = sched.catchUp();
    // While the first run hangs, another trigger arrives for the same id.
    await sched.catchUp();
    expect(runner.firedIds, ["r1"]);
    runner.gate!.complete();
    await first;
    expect(runner.firedIds, ["r1"]);
  });

  test("sync arms every enabled reminder and cancels the dropped ones", () async {
    final kept = reminder(id: "kept", nextFireAt: DateTime(2026, 9), code: 3);
    await list.write([kept, reminder(id: "dropped", nextFireAt: DateTime(2026, 9), code: 4)]);
    final sched = scheduler(list, runner, alarms);
    await sched.reload();
    expect(alarms.scheduled.keys.toSet(), {3, 4});

    await list.write([kept]);
    await sched.reload();

    expect(alarms.cancelled, [4]);
    expect(alarms.scheduled.keys, [3]);
  });

  test("the nudge path claims only what the system noticed", () async {
    final nudged = reminder(id: "nudged", nextFireAt: DateTime(2000), code: 7);
    await list.write([
      nudged,
      reminder(id: "other", nextFireAt: DateTime(2000), code: 8),
    ]);
    final sched = scheduler(list, runner, alarms);

    alarms.fire("nudged");
    await sched.onNudged();

    expect(runner.firedIds, ["nudged"]);
  });
}
