import "package:agent_chat/app/settings/triggers.dart";
import "package:entoli_core/model/trigger.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final now = DateTime(2026, 11, 11, 9, 41);

  TriggerDraft draft([Trigger? trigger]) => TriggerDraft(trigger, now: now);

  test("refuses a one-shot time in the past, and no prompt", () {
    final d = draft()..prompt = "Check the build";
    expect(d.refusal, isNull);
    d.source = ScheduleSource(at: DateTime(2020));
    expect(d.refusal, "Pick a time in the future.");
    d
      ..source = ScheduleSource(at: now.add(const Duration(hours: 1)))
      ..prompt = " ";
    expect(d.refusal, "Write the prompt first.");
  });

  test("asks for paths and a change where it watches files", () {
    final d = draft()
      ..prompt = "Summarise"
      ..kind = TriggerKind.file;
    expect(d.refusal, "Name at least one path to watch.");
    d.source = const FileSource(paths: ["project:notes.md"], events: {});
    expect(d.refusal, startsWith("Pick what a change is"));
  });

  test("a countdown runs from the save, and fires after it", () {
    final d = draft()
      ..prompt = "Stand up"
      ..member = "explore"
      ..source = TimerSource(
        duration: const Duration(minutes: 45),
        registeredAt: DateTime(2020),
      );
    final saved = now.add(const Duration(minutes: 3));
    final made = d.build(at: saved, projects: const []);
    final source = made.source as TimerSource;
    expect(source.duration, const Duration(minutes: 45));
    expect(source.registeredAt, saved);
    expect(made.nextFireAt, saved.add(const Duration(minutes: 45)));
    expect(made.member, "explore");
    expect(made.enabled, isTrue);
  });

  test("refuses a countdown of nothing", () {
    final d = draft()
      ..prompt = "Stand up"
      ..source = TimerSource(duration: Duration.zero, registeredAt: now);
    expect(d.refusal, "Set a countdown of at least a minute.");
  });

  test("an edit keeps a file watch's cooldown", () {
    final d = draft(
      Trigger(
        id: "t",
        name: "",
        prompt: "Summarise",
        source: const FileSource(
          paths: ["notes.md"],
          cooldown: Duration(minutes: 2),
        ),
      ),
    );
    final source = d.build(at: now, projects: const []).source as FileSource;
    expect(source.cooldown, const Duration(minutes: 2));
  });

  test("a trigger whose project is gone is saved into the default", () {
    final d = draft(
      Trigger(
        id: "t",
        name: "",
        prompt: "Ping",
        source: ScheduleSource(at: now.add(const Duration(hours: 1))),
        project: "deleted",
      ),
    );
    expect(d.build(at: now, projects: const ["kept"]).project, isNull);
    d.project = "kept";
    expect(d.build(at: now, projects: const ["kept"]).project, "kept");
    // Before the project list has loaded, nothing is known to be deleted.
    d.project = "deleted";
    expect(d.build(at: now, projects: null).project, "deleted");
  });

  test("one the agent registered is never refused, being never saved", () {
    final d = draft(
      Trigger(
        id: "t",
        name: "",
        prompt: "",
        source: ScheduleSource(at: now.add(const Duration(hours: 1))),
        byAgent: true,
      ),
    );
    expect(d.registered, isTrue);
    expect(d.refusal, isNull);
  });

  test("switching kind and back keeps what each held", () {
    final d = draft()..prompt = "x";
    final at = now.add(const Duration(days: 2));
    d
      ..source = ScheduleSource(at: at, repeat: ScheduleRepeat.daily)
      ..kind = TriggerKind.timer;
    expect(d.source, isA<TimerSource>());
    d.kind = TriggerKind.schedule;
    final back = d.source as ScheduleSource;
    expect(back.at, at);
    expect(back.repeat, ScheduleRepeat.daily);
    expect(d.edited, isTrue);
  });

  test("an untouched draft is not edited", () {
    final d = draft(
      Trigger(
        id: "t",
        name: "Sweep",
        prompt: "Ping",
        source: ScheduleSource(at: now.add(const Duration(hours: 1))),
      ),
    );
    expect(d.edited, isFalse);
    d.name = "Other";
    expect(d.edited, isTrue);
  });
}
