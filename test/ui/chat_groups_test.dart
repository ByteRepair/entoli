import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/sidebar/chat_groups.dart";

void main() {
  final now = DateTime(2026, 8, 17, 14, 30);

  ChatState chat(String title, DateTime updatedAt) => ChatState(
        id: title,
        title: title,
        createdAt: DateTime(2026),
        updatedAt: updatedAt,
      );

  /// A pinned chat, which is the one shape `groupChatsByDate` reads the flag
  /// from. Defaults to "now" so it lands at the top of the Pinned group.
  ChatState pinnedChat(String title, {DateTime? updatedAt, bool pinned = true}) =>
      chat(title, updatedAt ?? now).copyWith(pinned: pinned);

  /// The headings in the order they are drawn, which is the order the chats
  /// come in rather than a rank of their own.
  List<String> headingsOf(Iterable<ChatState> chats) =>
      groupChatsByDate(chats, now: now).map((g) => g.heading).toList();

  group("grouping", () {
    test("the day, then the days, then the weeks, then the month", () {
      final headings = headingsOf([
        chat("this morning", now.subtract(const Duration(hours: 6))),
        chat("last night", DateTime(2026, 8, 16, 23)),
        chat("midweek", DateTime(2026, 8, 13)),
        chat("a fortnight ago", DateTime(2026, 8, 2)),
        chat("in the spring", DateTime(2026, 4, 9)),
      ]);

      expect(headings, [
        "Today",
        "Yesterday",
        "Previous 7 days",
        "Previous 30 days",
        "April",
      ]);
    });

    test("a heading holds every chat of its own age, newest first", () {
      final groups = groupChatsByDate([
        chat("older", DateTime(2026, 8, 17, 9)),
        chat("newer", DateTime(2026, 8, 17, 13)),
        chat("yesterday's", DateTime(2026, 8, 16, 20)),
      ], now: now);

      expect(groups, hasLength(2));
      expect(groups.first.heading, "Today");
      expect(groups.first.chats.map((c) => c.title), ["newer", "older"]);
      expect(groups.last.chats.single.title, "yesterday's");
    });

    // The month alone would put August 2025 and August 2026 under one heading.
    test("a month of another year carries the year", () {
      expect(headingsOf([chat("last summer", DateTime(2025, 8, 20))]), ["August 2025"]);
    });

    // Boundaries: a day counted wrong is a chat under the wrong heading, and
    // the six-and-seven pair is where the weeks give way to the month.
    test("six days back is the week and seven is the month", () {
      expect(headingsOf([chat("six", DateTime(2026, 8, 11))]), ["Previous 7 days"]);
      expect(headingsOf([chat("seven", DateTime(2026, 8, 10))]), ["Previous 30 days"]);
    });

    test("a chat dated in the future is today rather than nowhere", () {
      expect(headingsOf([chat("tomorrow", now.add(const Duration(days: 1)))]), ["Today"]);
    });

    test("nothing groups to nothing", () {
      expect(groupChatsByDate(const [], now: now), isEmpty);
    });

    // Pinned chats are drawn under their own heading ahead of every date group,
    // newest first among themselves. The category is a fact the user set, not
    // a date the reader has to place, so a single pinned chat still gets it.
    group("pinned", () {
      test("a pinned chat sits under Pinned", () {
        final groups = groupChatsByDate([pinnedChat("kept")], now: now);
        expect(groups, hasLength(1));
        expect(groups.first.heading, pinnedHeading);
        expect(groups.first.chats.single.title, "kept");
      });

      test("Pinned comes before every date group", () {
        final headings = headingsOf([
          pinnedChat("kept", updatedAt: DateTime(2026, 4, 9)),
          chat("today", now),
        ]);
        expect(headings.first, pinnedHeading);
        expect(headings, [pinnedHeading, "Today"]);
      });

      test("pinned chats sort newest first within the group", () {
        final groups = groupChatsByDate([
          pinnedChat("older", updatedAt: DateTime(2026, 8, 17, 9)),
          pinnedChat("newer", updatedAt: DateTime(2026, 8, 17, 13)),
        ], now: now);
        expect(groups, hasLength(1));
        expect(groups.first.heading, pinnedHeading);
        expect(groups.first.chats.map((c) => c.title), ["newer", "older"]);
      });

      test("unpinned chats keep their date grouping", () {
        final groups = groupChatsByDate([
          pinnedChat("kept"),
          pinnedChat("released", pinned: false),
        ], now: now);
        expect(groups.map((g) => g.heading), [pinnedHeading, "Today"]);
        expect(groups.last.chats.single.title, "released");
      });
    });
  });

  group("searching", () {
    final chats = [
      chat("Porting the shell", DateTime(2026, 8, 17)),
      chat("Shelling out", DateTime(2026, 8, 16)),
      chat("", DateTime(2026, 8, 15)),
    ];

    test("matches part of a title, whatever the case", () {
      expect(
        chatsMatching(chats, "SHELL").map((c) => c.title),
        ["Porting the shell", "Shelling out"],
      );
    });

    test("an empty query, or one of spaces, keeps everything", () {
      expect(chatsMatching(chats, ""), hasLength(3));
      expect(chatsMatching(chats, "   "), hasLength(3));
    });

    // What is searched is what the row shows, so a chat the title model never
    // named is found under the name it is drawn with.
    test("an untitled chat is found by what it is shown as", () {
      expect(chatsMatching(chats, "untitled"), hasLength(1));
    });

    test("nothing matching is empty rather than everything", () {
      expect(chatsMatching(chats, "compiler"), isEmpty);
    });
  });
}
