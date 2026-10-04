import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/trigger.dart";

void main() {
  group("schedule nextOccurrence", () {
    test("a future one-shot is due at its own time", () {
      final at = DateTime(2026, 8, 22, 9);
      final trigger = Trigger(
          id: "r",
          name: "",
          prompt: "",
          source: ScheduleSource(at: at));
      expect(trigger.nextOccurrence(DateTime(2026, 1, 1)), at);
    });

    test("a past one-shot has nothing ahead of it", () {
      final at = DateTime(2026, 8, 22, 9);
      final trigger = Trigger(
          id: "r",
          name: "",
          prompt: "",
          source: ScheduleSource(at: at));
      expect(trigger.nextOccurrence(DateTime(2026, 9, 1)), isNull);
    });

    test("hourly keeps its minute and moves one hour", () {
      // Anchored at :30, so after 09:20 the next is 09:30, then 10:30.
      final at = DateTime(2026, 8, 22, 9, 30);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.hourly),
      );
      expect(trigger.nextOccurrence(DateTime(2026, 8, 22, 9, 20)),
          DateTime(2026, 8, 22, 9, 30));
      expect(trigger.nextOccurrence(DateTime(2026, 8, 22, 9, 30)),
          DateTime(2026, 8, 22, 10, 30));
    });

    test("daily keeps its time of day across a month end", () {
      final at = DateTime(2026, 8, 31, 23, 45);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.daily),
      );
      expect(
        trigger.nextOccurrence(DateTime(2026, 8, 31, 23, 45)),
        DateTime(2026, 9, 1, 23, 45),
      );
    });

    test("weekly keeps its weekday", () {
      // Aug 22 2026 is a Saturday.
      final at = DateTime(2026, 8, 22, 8);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.weekly),
      );
      final next = trigger.nextOccurrence(at)!;
      expect(next, DateTime(2026, 8, 29, 8));
      expect(next.weekday, at.weekday);
    });

    test("monthly clamps into short months and returns to the anchor day", () {
      final at = DateTime(2027, 1, 31, 9);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.monthly),
      );
      // 2027 is not a leap year.
      expect(trigger.nextOccurrence(at), DateTime(2027, 2, 28, 9));
      // Back on its own day the month after, because every step derives from
      // the anchor's day rather than the last occurrence's.
      expect(
        trigger.nextOccurrence(DateTime(2027, 2, 28, 9)),
        DateTime(2027, 3, 31, 9),
      );
    });

    test("monthly clamps into a leap February", () {
      final at = DateTime(2027, 1, 30, 9);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.monthly),
      );
      expect(trigger.nextOccurrence(at), DateTime(2027, 2, 28, 9));
      final leapAnchor = DateTime(2028, 1, 30, 9);
      final leap = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: leapAnchor, repeat: ScheduleRepeat.monthly),
      );
      expect(leap.nextOccurrence(leapAnchor), DateTime(2028, 2, 29, 9));
    });

    test("a long-past-due daily walks forward to tomorrow, not to its anchor", () {
      final at = DateTime(2020, 1, 1, 7);
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: ScheduleSource(at: at, repeat: ScheduleRepeat.daily),
      );
      expect(
        trigger.nextOccurrence(DateTime(2026, 8, 22, 12)),
        DateTime(2026, 8, 23, 7),
      );
    });
  });

  group("timer nextAfter", () {
    test("counts from when it was registered", () {
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: TimerSource(
            duration: const Duration(minutes: 30),
            registeredAt: DateTime(2026, 8, 22, 9)),
      );
      expect(
          trigger.nextOccurrence(DateTime(2026, 8, 22, 9, 20)),
          DateTime(2026, 8, 22, 9, 30));
    });

    test("an elapsed countdown has nothing ahead of it", () {
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: TimerSource(
            duration: const Duration(minutes: 30),
            registeredAt: DateTime(2026, 8, 22, 9)),
      );
      expect(trigger.nextOccurrence(DateTime(2026, 8, 22, 9, 31)), isNull);
    });
  });

  group("file source", () {
    test("is never on the clock", () {
      final trigger = Trigger(
        id: "r",
        name: "",
        prompt: "",
        source: const FileSource(paths: ["notes.md"]),
      );
      expect(trigger.nextOccurrence(DateTime(2026, 9, 1)), isNull);
      expect(trigger.dueBy(DateTime(2100)), isFalse);
    });
  });

  group("json", () {
        test("round-trips every field of every kind", () {
          final original = Trigger(
            id: "id-1",
            name: "Standup notes",
            prompt: "/standup write it up",
            source: ScheduleSource(
                at: DateTime(2026, 8, 22, 9), repeat: ScheduleRepeat.daily),
            project: "work",
            tempChatTtl: TempChatTtl.days7,
            enabled: false,
            byAgent: true,
            lastFiredAt: DateTime(2026, 8, 21, 9),
            nextFireAt: DateTime(2026, 8, 23, 9),
            requestCode: 4,
          );

          final back = Trigger.fromJson(original.toJson());
          expect(back.id, "id-1");
          expect(back.name, "Standup notes");
          expect(back.prompt, "/standup write it up");
          final schedule = back.source as ScheduleSource;
          expect(schedule.at, DateTime(2026, 8, 22, 9));
          expect(schedule.repeat, ScheduleRepeat.daily);
          expect(back.project, "work");
          expect(back.tempChatTtl, TempChatTtl.days7);
          expect(back.enabled, isFalse);
          expect(back.byAgent, isTrue);
          expect(back.lastFiredAt, DateTime(2026, 8, 21, 9));
          expect(back.nextFireAt, DateTime(2026, 8, 23, 9));
          expect(back.requestCode, 4);
        });

        test("round-trips a timer", () {
          final original = Trigger(
            id: "t",
            name: "nag",
            prompt: "p",
            source: TimerSource(
                duration: const Duration(minutes: 45),
                registeredAt: DateTime(2026, 8, 22, 9)),
          );
          final back = Trigger.fromJson(original.toJson());
          final timer = back.source as TimerSource;
          expect(timer.duration, const Duration(minutes: 45));
          expect(timer.registeredAt, DateTime(2026, 8, 22, 9));
        });

        test("round-trips a file source, defaults included", () {
          final original = Trigger(
            id: "f",
            name: "watch",
            prompt: "p",
            source: const FileSource(paths: ["build.log"], events: {FileEvent.change}),
          );
          final back = Trigger.fromJson(original.toJson());
          final file = back.source as FileSource;
          expect(file.paths, ["build.log"]);
          expect(file.events, {FileEvent.change});
          expect(file.cooldown, const Duration(seconds: 5));
        });

        test("a shape the reader falls back past stays a schedule", () {
          // A later build wrote "fortnightly": no such kind or repeat in this
          // one, and the loss is the fire rather than the list.
          final back = Trigger.fromJson({
            "id": "x",
            "source": {
              "kind": "fortnightly",
              "at": DateTime(2026, 8, 22, 9).toIso8601String(),
            },
          });
          expect(back.source, isA<ScheduleSource>());
          expect((back.source as ScheduleSource).repeat, ScheduleRepeat.off);
        });

        test("a file written by an older build reads with defaults", () {
          final trigger = Trigger.fromJson(
              {"id": "old", "at": DateTime(2026, 1).toIso8601String()});
          expect(trigger.name, "");
          expect(trigger.tempChatTtl, isNull);
          expect(trigger.enabled, isTrue);
          expect(trigger.requestCode, isNull);
          // The flat at/repeat keys are the schedule's: every reminder file
          // ever written reads as triggers without a migration.
          expect(trigger.source, isA<ScheduleSource>());
          expect((trigger.source as ScheduleSource).at, DateTime(2026, 1));
        });

        test("the temporary bool an older build wrote reads as the TTL it meant",
            () {
          final at = DateTime(2026, 1).toIso8601String();
          expect(
            Trigger.fromJson({"id": "kept", "at": at, "temporary": false})
                .tempChatTtl,
            TempChatTtl.off,
          );
          expect(
            Trigger.fromJson({"id": "temp", "at": at, "temporary": true})
                .tempChatTtl,
            isNull,
          );
        });
  });
}
