import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";

void main() {
  group("nextOccurrence", () {
    test("a future one-shot is due at its own time", () {
      final at = DateTime(2026, 8, 22, 9);
      final reminder = Reminder(id: "r", name: "", prompt: "", at: at);
      expect(reminder.nextOccurrence(DateTime(2026, 1, 1)), at);
    });

    test("a past one-shot has nothing ahead of it", () {
      final at = DateTime(2026, 8, 22, 9);
      final reminder = Reminder(id: "r", name: "", prompt: "", at: at);
      expect(reminder.nextOccurrence(DateTime(2026, 9, 1)), isNull);
    });

    test("hourly keeps its minute and moves one hour", () {
      // 10:15 is the next slot after 09:20 for a reminder anchored at :00? No —
      // anchored at :30, so after 09:20 the next is 09:30, then 10:30.
      final at = DateTime(2026, 8, 22, 9, 30);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.hourly,
      );
      expect(reminder.nextOccurrence(DateTime(2026, 8, 22, 9, 20)), DateTime(2026, 8, 22, 9, 30));
      expect(reminder.nextOccurrence(DateTime(2026, 8, 22, 9, 30)), DateTime(2026, 8, 22, 10, 30));
    });

    test("daily keeps its time of day across a month end", () {
      final at = DateTime(2026, 8, 31, 23, 45);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.daily,
      );
      expect(
        reminder.nextOccurrence(DateTime(2026, 8, 31, 23, 45)),
        DateTime(2026, 9, 1, 23, 45),
      );
    });

    test("weekly keeps its weekday", () {
      // Aug 22 2026 is a Saturday.
      final at = DateTime(2026, 8, 22, 8);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.weekly,
      );
      final next = reminder.nextOccurrence(at)!;
      expect(next, DateTime(2026, 8, 29, 8));
      expect(next.weekday, at.weekday);
    });

    test("monthly clamps into short months and returns to the anchor day", () {
      final at = DateTime(2027, 1, 31, 9);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.monthly,
      );
      // 2027 is not a leap year.
      expect(reminder.nextOccurrence(at), DateTime(2027, 2, 28, 9));
      // Back on its own day the month after, because every step derives from
      // the anchor's day rather than the last occurrence's.
      expect(
        reminder.nextOccurrence(DateTime(2027, 2, 28, 9)),
        DateTime(2027, 3, 31, 9),
      );
    });

    test("monthly clamps into a leap February", () {
      final at = DateTime(2027, 1, 30, 9);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.monthly,
      );
      expect(reminder.nextOccurrence(at), DateTime(2027, 2, 28, 9));
      final leapAnchor = DateTime(2028, 1, 30, 9);
      final leap = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: leapAnchor,
        repeat: ReminderRepeat.monthly,
      );
      expect(leap.nextOccurrence(leapAnchor), DateTime(2028, 2, 29, 9));
    });

    test("a long-past-due daily walks forward to tomorrow, not to its anchor", () {
      final at = DateTime(2020, 1, 1, 7);
      final reminder = Reminder(
        id: "r",
        name: "",
        prompt: "",
        at: at,
        repeat: ReminderRepeat.daily,
      );
      expect(
        reminder.nextOccurrence(DateTime(2026, 8, 22, 12)),
        DateTime(2026, 8, 23, 7),
      );
    });
  });

  group("json", () {
    test("round-trips every field", () {
      final reminder = Reminder(
        id: "id-1",
        name: "Standup notes",
        prompt: "/standup write it up",
        at: DateTime(2026, 8, 22, 9),
        repeat: ReminderRepeat.daily,
        project: "work",
        tempChatTtl: TempChatTtl.days7,
        enabled: false,
        lastFiredAt: DateTime(2026, 8, 21, 9),
        nextFireAt: DateTime(2026, 8, 23, 9),
        requestCode: 4,
      ).toJson();

      final back = Reminder.fromJson(reminder);
      expect(back.id, "id-1");
      expect(back.name, "Standup notes");
      expect(back.prompt, "/standup write it up");
      expect(back.at, DateTime(2026, 8, 22, 9));
      expect(back.repeat, ReminderRepeat.daily);
      expect(back.project, "work");
      expect(back.tempChatTtl, TempChatTtl.days7);
      expect(back.enabled, isFalse);
      expect(back.lastFiredAt, DateTime(2026, 8, 21, 9));
      expect(back.nextFireAt, DateTime(2026, 8, 23, 9));
      expect(back.requestCode, 4);
    });

    test("an unknown repeat name falls back rather than failing the load", () {
      final reminder = Reminder.fromJson({
        "id": "x",
        "at": DateTime(2026, 8, 22, 9).toIso8601String(),
        "repeat": "fortnightly",
      });
      expect(reminder.repeat, ReminderRepeat.off);
    });

    test("a file written by an older build reads with defaults", () {
      final reminder = Reminder.fromJson({"id": "old", "at": DateTime(2026, 1).toIso8601String()});
      expect(reminder.name, "");
      expect(reminder.tempChatTtl, isNull);
      expect(reminder.enabled, isTrue);
      expect(reminder.requestCode, isNull);
    });

    test("the temporary bool an older build wrote reads as the TTL it meant", () {
      final at = DateTime(2026, 1).toIso8601String();
      expect(
        Reminder.fromJson({"id": "kept", "at": at, "temporary": false}).tempChatTtl,
        TempChatTtl.off,
      );
      expect(
        Reminder.fromJson({"id": "temp", "at": at, "temporary": true}).tempChatTtl,
        isNull,
      );
    });
  });
}
