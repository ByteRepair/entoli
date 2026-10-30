import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/sub_agent_log.dart";

void main() {
  ChatRecord text(String t, {int index = 0}) =>
      ChatRecord.append(messageId: "call-1", index: index, text: t);

  group("growing a transcript", () {
    final held = [text("a"), text("b")];

    test("takes an append numbered where it ends", () {
      expect(growTranscript(held, 2, [text("c")]), [...held, text("c")]);
    });

    test("skips what it already has of one that overlaps", () {
      expect(growTranscript(held, 1, [text("b"), text("c")]), [
        ...held,
        text("c"),
      ]);
      expect(growTranscript(held, 0, [text("a")]), held);
    });

    test("says a gap is one, rather than joining across it", () {
      expect(growTranscript(held, 3, [text("d")]), isNull);
    });
  });

  group("the feed", () {
    test(
      "holds a run from what it already had, and numbers each append",
      () async {
        final feed = SubAgentFeed();
        final appends = <SubAgentAppend>[];
        feed.appends.listen(appends.add);

        feed.open("chat", "call-1", [text("old")]);
        feed.add("chat", "call-1", [text("new")]);
        await Future<void>.delayed(Duration.zero);

        expect(feed.held("chat", "call-1"), [text("old"), text("new")]);
        expect(appends.single.from, 1);
        expect(appends.single.records, [text("new")]);
      },
    );

    test("lets a run go when its log closes", () async {
      final feed = SubAgentFeed()..open("chat", "call-1", const []);

      feed.add("chat", "call-1", [
        text("done"),
        const ChatRecord.turnEnd(messageId: "call-1", reason: TurnEnd.done),
      ]);

      expect(feed.holds("chat", "call-1"), isFalse);
    });

    test("says nothing of a run it was never told about", () async {
      final feed = SubAgentFeed();
      final appends = <SubAgentAppend>[];
      feed.appends.listen(appends.add);

      feed.add("chat", "call-1", [text("stray")]);
      await Future<void>.delayed(Duration.zero);

      expect(appends, isEmpty);
      expect(feed.held("chat", "call-1"), isNull);
    });
  });
}
