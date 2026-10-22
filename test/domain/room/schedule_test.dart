import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project_settings.dart" show OmadaOrdering;
import "package:agent_chat/domain/room/schedule.dart";

Message _msg(String id, {MessageRole role = MessageRole.user}) =>
    Message(id: id, role: role, createdAt: DateTime(2026));

void main() {
  /// One dispatch, recording who ran what. [busy] is fixed for the pass, the
  /// way a room with turns already in flight reads it.
  Future<List<(String?, String)>> dispatch(Schedule s, OmadaOrdering o,
      {int cap = 10, Set<String?> busy = const {}}) async {
    final ran = <(String?, String)>[];
    await s.dispatch(
        ordering: () => o, cap: () => cap, busy: () => busy,
        run: (member, item) async {
      ran.add((member, (item.userPrompt ?? item.reply)!.id));
    });
    return ran;
  }

  test("sequential runs one item a pass, parallel one per member", () async {
    for (final (o, want) in [
      (OmadaOrdering.sequential, 1),
      (OmadaOrdering.parallel, 2),
      (OmadaOrdering.relay, 2),
    ]) {
      final s = Schedule()..addPrompt(["a", "b"], _msg("p"));
      expect(await dispatch(s, o), hasLength(want), reason: o.name);
    }
  });

  test("relay skips a member with a turn in flight and keeps their item",
      () async {
    final s = Schedule()..addPrompt(["a", "b"], _msg("p"));
    expect(await dispatch(s, OmadaOrdering.relay, busy: {"a"}), [("b", "p")]);
    expect(await dispatch(s, OmadaOrdering.relay), [("a", "p")]);
    expect(s.isEmpty, isTrue);
  });

  test("a prompt naming nobody is the house's", () async {
    final s = Schedule()..addPrompt(const [], _msg("p"));
    expect(await dispatch(s, OmadaOrdering.sequential), [(null, "p")]);
  });

  test("a reply naming nobody queues nothing", () {
    final s = Schedule()
      ..addHandoff(const [], _msg("r", role: MessageRole.assistant),
          generation: 0, thread: const []);
    expect(s.isEmpty, isTrue);
  });

  test("the cap drops a handoff head and keeps the user's words behind it",
      () async {
    final r = _msg("r", role: MessageRole.assistant);
    final s = Schedule()
      ..addHandoff(["a"], r, generation: 1, thread: [r])
      ..addPrompt(["a"], _msg("p"));
    // The handoff is generation 2, at the cap: dropped, not run.
    expect(await dispatch(s, OmadaOrdering.parallel, cap: 2), isEmpty);
    expect(await dispatch(s, OmadaOrdering.parallel, cap: 2), [("a", "p")]);
  });

  test("a member holds one handoff: the later reply, the deeper generation",
      () async {
    final early = _msg("early", role: MessageRole.assistant);
    final late = _msg("late", role: MessageRole.assistant);
    final thread = [early, late];
    final s = Schedule()
      ..addHandoff(["a"], late, generation: 3, thread: thread)
      ..addHandoff(["a"], early, generation: 0, thread: thread);
    final items = <ScheduledItem>[];
    await s.dispatch(
        ordering: () => OmadaOrdering.parallel,
        cap: () => 10,
        busy: () => {},
        run: (_, item) async => items.add(item));
    expect(items.single.reply, late);
    expect(items.single.generation, 4);
    expect(s.isEmpty, isTrue);
  });

  test("a dispatch asked mid-pass runs as a second pass, not beside it",
      () async {
    final s = Schedule()..addPrompt(["a"], _msg("p1"));
    final ran = <String>[];
    Future<void> run(String? member, ScheduledItem item) async {
      ran.add(item.userPrompt!.id);
      if (ran.length == 1) {
        s.addPrompt(["b"], _msg("p2"));
        // Re-entered while the first pass is still running its item.
        await s.dispatch(
            ordering: () => OmadaOrdering.sequential,
            cap: () => 10,
            busy: () => {},
            run: run);
        expect(ran, ["p1"], reason: "the re-entry ran nothing itself");
      }
    }

    await s.dispatch(
        ordering: () => OmadaOrdering.sequential,
        cap: () => 10,
        busy: () => {},
        run: run);
    expect(ran, ["p1", "p2"]);
  });

  test("each pass reads the ordering afresh", () async {
    final s = Schedule()..addPrompt(["a", "b"], _msg("p1"));
    var ordering = OmadaOrdering.sequential;
    final ran = <String?>[];
    Future<void> run(String? member, ScheduledItem item) async {
      ran.add(member);
      if (ran.length == 1) {
        ordering = OmadaOrdering.parallel;
        s.addPrompt(["c"], _msg("p2"));
        await s.dispatch(
            ordering: () => ordering,
            cap: () => 10,
            busy: () => {},
            run: run);
      }
    }

    await s.dispatch(
        ordering: () => ordering, cap: () => 10, busy: () => {}, run: run);
    // The first pass ran "a" alone; the pass the re-entry asked for ran the
    // rest at once under the ordering it was switched to.
    expect(ran, ["a", "b", "c"]);
  });

  test("a settle hands off the parked replies first, and forgets the rest",
      () {
    final s = Schedule()
      ..finished("a", 1)
      ..finished("b", 2)
      ..finished("stale", 5)
      ..park("a");
    expect(s.settle("b"), ["a", "b"]);
    expect(s.generationOf("b"), 2);
    expect(s.generationOf("stale"), 0);
    expect(s.settle(null), isEmpty);
  });

  test("an item is a prompt or a handoff", () {
    expect(() => ScheduledItem(generation: 0), throwsA(isA<AssertionError>()));
  });

  group("ordering policy", () {
    test("only relay skips the wave", () {
      expect(OmadaOrdering.sequential.waitsForWave, isTrue);
      expect(OmadaOrdering.parallel.waitsForWave, isTrue);
      expect(OmadaOrdering.relay.waitsForWave, isFalse);
    });

    test("what each admits", () {
      expect(OmadaOrdering.sequential.admits(started: 1, memberBusy: false),
          isFalse);
      expect(OmadaOrdering.parallel.admits(started: 5, memberBusy: true),
          isTrue);
      expect(OmadaOrdering.relay.admits(started: 5, memberBusy: true), isFalse);
    });
  });
}
