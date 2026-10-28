import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  final at = DateTime.utc(2026, 1, 1);

  ChatRecord message(String id, [MessageRole role = MessageRole.user]) =>
      ChatRecord.message(id: id, role: role, createdAt: at);

  /// A message opening a thread beside [of] rather than continuing the one
  /// being read.
  ChatRecord branch(String id, {required String of, MessageRole role = MessageRole.user}) =>
      ChatRecord.message(id: id, role: role, createdAt: at, siblingOf: of);

  ChatState state() => ChatState(id: "c", title: "t", createdAt: at, updatedAt: at);

  ChatRecord part(String message, int index, String text) =>
      ChatRecord.part(messageId: message, index: index, part: MessagePart.text(text: text));

  String textOf(Message m) => m.plainText;

  test("replay folds messages and their parts back in order", () {
    final messages = replay([
      message("m1"),
      part("m1", 0, "hello"),
      message("m2", MessageRole.assistant),
      part("m2", 0, "hi"),
      ChatRecord.turnEnd(messageId: "m2", reason: TurnEnd.done),
    ]);

    expect(messages, hasLength(2));
    expect(messages[0].role, MessageRole.user);
    expect(textOf(messages[0]), "hello");
    expect(messages[1].role, MessageRole.assistant);
    expect(textOf(messages[1]), "hi");
  });

  test("a part written again at the same index supersedes it", () {
    final messages = replay([
      message("m1", MessageRole.assistant),
      part("m1", 0, "par"),
      part("m1", 0, "partial"),
      part("m1", 0, "partial answer"),
    ]);

    expect(messages.single.parts, hasLength(1));
    expect(textOf(messages.single), "partial answer");
  });

  test("supersession reaches a part that is no longer last", () {
    // What closing a thinking block looks like: the block is timed after a
    // tool call has already landed behind it.
    final messages = replay([
      message("m1", MessageRole.assistant),
      ChatRecord.part(
          messageId: "m1", index: 0, part: const MessagePart.reasoning(text: "hmm")),
      part("m1", 1, "and so"),
      ChatRecord.part(
          messageId: "m1",
          index: 0,
          part: const MessagePart.reasoning(text: "hmm", durationMs: 1200)),
    ]);

    final reasoning = messages.single.parts.first as ReasoningPart;
    expect(reasoning.durationMs, 1200);
    expect(messages.single.parts, hasLength(2));
  });

  group("growing text", () {
    test("an append lands on the end of the part it names", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        part("m1", 0, "one"),
        const ChatRecord.append(messageId: "m1", index: 0, text: " two"),
        const ChatRecord.append(messageId: "m1", index: 0, text: " three"),
      ]);

      expect(textOf(messages.single), "one two three");
    });

    test("an append naming a part that cannot hold text is ignored", () {
      final messages = replay([
        message("m1", MessageRole.assistant),
        const ChatRecord.part(
            messageId: "m1",
            index: 0,
            part: MessagePart.toolCall(toolCall: ToolCall(id: "c1", name: "bash"))),
        const ChatRecord.append(messageId: "m1", index: 0, text: "nope"),
      ]);

      expect(messages.single.parts.single, isA<ToolCallPart>());
    });

    // What decides between an append and writing the part again.
    test("only growth is written as a piece; anything else goes whole", () {
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "one two")),
          " two");
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "different")),
          isNull);
      expect(
          textGrownFrom(
              const MessagePart.text(text: "one"), const MessagePart.text(text: "one")),
          isNull);
      // A thinking block being timed as it closes changed more than its text.
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hm", durationMs: 12)),
          isNull);
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hmmm")),
          "mm");
      // So did one being signed, and one belonging to another response.
      expect(
          textGrownFrom(const MessagePart.reasoning(text: "hm"),
              const MessagePart.reasoning(text: "hmmm", signature: "sig")),
          isNull);
      expect(
          textGrownFrom(const MessagePart.text(text: "one", responseId: "r1"),
              const MessagePart.text(text: "one two", responseId: "r2")),
          isNull);
      expect(
          textGrownFrom(const MessagePart.text(text: "one", responseId: "r1"),
              const MessagePart.text(text: "one two", responseId: "r1")),
          " two");
    });

    test("an append keeps what the part it lands on already carried", () {
      // A thinking block's timing, signature and response survive growth.
      final messages = replay([
        message("m1", MessageRole.assistant),
        const ChatRecord.part(
            messageId: "m1",
            index: 0,
            part: MessagePart.reasoning(
                text: "hm", durationMs: 40, signature: "sig", responseId: "r1")),
        const ChatRecord.append(messageId: "m1", index: 0, text: "mm"),
      ]);

      final block = messages.single.parts.single as ReasoningPart;
      expect(block.text, "hmmm");
      expect(block.durationMs, 40);
      expect(block.signature, "sig");
      expect(block.responseId, "r1");
    });
  });

  test("rewind drops its message and everything after it", () {
    final messages = replay([
      message("m1"),
      part("m1", 0, "first"),
      message("m2", MessageRole.assistant),
      part("m2", 0, "answer"),
      message("m3"),
      part("m3", 0, "second"),
      ChatRecord.rewind(messageId: "m2"),
      message("m4", MessageRole.assistant),
      part("m4", 0, "again"),
    ]);

    expect(messages.map(textOf), ["first", "again"]);
  });

  test("records naming nothing are skipped rather than thrown on", () {
    final messages = replay([
      part("gone", 0, "orphan"),
      message("m1"),
      part("m1", 4, "past the end"),
      part("m1", 0, "kept"),
      ChatRecord.rewind(messageId: "never"),
    ]);

    expect(messages.single.parts, hasLength(1));
    expect(textOf(messages.single), "kept");
  });

  group("threads", () {
    /// One finished exchange, which is what an edit or a regenerate branches.
    List<ChatRecord> oneTurn() => [
          message("u1"),
          part("u1", 0, "hello"),
          message("a1", MessageRole.assistant),
          part("a1", 0, "hi"),
        ];

    test("a branch is read in place of what it replaces, which stays", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "hello again"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hello again"]);
      expect(replayed.branches, {
        "a2": ["a1", "a2"]
      });
    });

    // The case a parent named on the message could not express: the thread
    // replacing the first message of a chat has nothing above it to name.
    test("branching the first message has no parent to hang off", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("u2", of: "u1"),
        part("u2", 0, "goodbye"),
        message("a2", MessageRole.assistant),
        part("a2", 0, "bye"),
      ]);

      expect(replayed.messages.map(textOf), ["goodbye", "bye"]);
      expect(replayed.branches, {
        "u2": ["u1", "u2"]
      });
    });

    test("what is written after a branch goes on the thread it opened", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "hello again"),
        message("u2"),
        part("u2", 0, "thanks"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hello again", "thanks"]);
    });

    test("select puts an earlier thread back, and what hung below it", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("u2", of: "u1"),
        part("u2", 0, "goodbye"),
        message("a2", MessageRole.assistant),
        part("a2", 0, "bye"),
        ChatRecord.select(messageId: "u1"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hi"]);
      expect(replayed.branches, {
        "u1": ["u1", "u2"]
      });
    });

    test("the last select wins, the way a superseded part does", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "hello again"),
        ChatRecord.select(messageId: "a1"),
        ChatRecord.select(messageId: "a2"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hello again"]);
    });

    test("deleting a thread falls back to the one beside it", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "hello again"),
        ChatRecord.rewind(messageId: "a2"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hi"]);
      // Nothing left to count once it is alone again.
      expect(replayed.branches, isEmpty);
    });

    test("deleting a thread takes everything below it", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("u2", of: "u1"),
        part("u2", 0, "goodbye"),
        message("a2", MessageRole.assistant),
        part("a2", 0, "bye"),
        ChatRecord.rewind(messageId: "u2"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hi"]);
    });

    test("a branch of a message that has gone goes on the end instead", () {
      final replayed = replayTree([
        ...oneTurn(),
        branch("u2", of: "never"),
        part("u2", 0, "thanks"),
      ]);

      expect(replayed.messages.map(textOf), ["hello", "hi", "thanks"]);
      expect(replayed.branches, isEmpty);
    });

    // Whether the log stops mid-turn is now a question about the thread being
    // read, so cycling changes the answer. The reply left open is the end of
    // its own thread, so carrying it on still only ever appends — which is the
    // reason the middle of a conversation was refused, and it does not apply.
    test("an interrupted thread is offered again once it is stepped back to", () {
      final log = [
        message("u1"),
        part("u1", 0, "hello"),
        message("a1", MessageRole.assistant),
        part("a1", 0, "half an"),
        // No turnEnd: this is where the process was killed.
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "a whole answer"),
        ChatRecord.turnEnd(messageId: "a2", reason: TurnEnd.done),
      ];

      expect(chatFrom(state(), log).unfinished, isFalse);
      expect(
          chatFrom(state(), [...log, ChatRecord.select(messageId: "a1")]).unfinished,
          isTrue);
    });

    test("the arrows stop at either end rather than wrapping", () {
      final chat = chatFrom(state(), [
        ...oneTurn(),
        branch("a2", of: "a1", role: MessageRole.assistant),
        part("a2", 0, "hello again"),
      ]);

      expect(chat.threadsAt("a2"), ["a1", "a2"]);
      expect(chat.threadIndex("a2"), 1);
      expect(chat.threadBeside("a2", -1), "a1");
      expect(chat.threadBeside("a2", 1), isNull);
      // A message nothing was branched at is a thread of one.
      expect(chat.threadsAt("u1"), ["u1"]);
      expect(chat.threadBeside("u1", -1), isNull);
    });
  });

  group("the turn a log stops in", () {
    bool unfinishedIn(List<ChatRecord> records) =>
        endsUnfinished(replay(records), records);

    /// A turn as it is written: the prompt, the reply, and whatever closed it.
    List<ChatRecord> turn({TurnEnd? end, String said = "do it"}) => [
          message("m1"),
          part("m1", 0, said),
          message("m2", MessageRole.assistant),
          part("m2", 0, "on it"),
          if (end != null) ChatRecord.turnEnd(messageId: "m2", reason: end),
        ];

    test("a reply with nothing closing it was being written when the process died",
        () => expect(unfinishedIn(turn()), isTrue));

    // Ended turns are not offered: a finished one because it finished, a
    // stopped one because the user has already said they want it to stop.
    test("a turn that ended is not offered", () {
      expect(unfinishedIn(turn(end: TurnEnd.done)), isFalse);
      expect(unfinishedIn(turn(end: TurnEnd.aborted)), isFalse);
    });

    test("a turn that gave up is offered, like one that was killed",
        () => expect(unfinishedIn(turn(end: TurnEnd.error)), isTrue));

    // Resuming appends to the reply, and a command has nothing to append: the
    // only way to carry one on would be to run it again.
    test("a command the user ran is never offered, however it was cut off", () {
      expect(unfinishedIn(turn(said: "!make")), isFalse);
      expect(unfinishedIn(turn(said: "!make", end: TurnEnd.error)), isFalse);
    });

    test("a log that ends on a prompt has no reply to carry on", () {
      expect(unfinishedIn([message("m1"), part("m1", 0, "do it")]), isFalse);
    });

    test("nothing written yet is nothing to carry on", () {
      expect(unfinishedIn([]), isFalse);
    });

    test("a reply that was rewound away is gone, not unfinished", () {
      expect(unfinishedIn([...turn(), ChatRecord.rewind(messageId: "m1")]), isFalse);
    });

    // A resumed turn closes the same message a second time, so the last record
    // is the one that says how it went.
    test("the last record naming the message wins", () {
      expect(
        unfinishedIn([
          ...turn(end: TurnEnd.error),
          part("m2", 1, " finished it"),
          ChatRecord.turnEnd(messageId: "m2", reason: TurnEnd.done),
        ]),
        isFalse,
      );
    });
  });

  test("a record survives the round trip through JSON", () {
    final records = [
      message("m1"),
      part("m1", 0, "hello"),
      const ChatRecord.part(
          messageId: "m1",
          index: 1,
          part: MessagePart.reasoning(text: "thinking", durationMs: 30)),
      const ChatRecord.part(
          messageId: "m1",
          index: 2,
          part: MessagePart.shellRun(
              command: "echo hello", returnCode: 0, output: "hello\n")),
      const ChatRecord.append(messageId: "m1", index: 0, text: " more"),
      ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.aborted),
      ChatRecord.rewind(messageId: "m1"),
      const ChatRecord.callEvent(
          callId: "c1",
          kind: jobEndedEvent,
          data: {"jobId": 1, "exitCode": 2, "tail": "boom"}),
    ];

    final back = records
        .map((r) => ChatRecord.fromJson(
            jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>))
        .toList();

    expect(back, records);
  });

  test("a call's event lands on the chat by the call, the last of a kind "
      "winning", () {
    JobEnd end(int? code) => JobEnd(jobId: 1, exitCode: code, tail: "");
    ChatRecord ended(int? code) => ChatRecord.callEvent(
        callId: "c1", kind: jobEndedEvent, data: end(code).toJson());
    final chat = chatFrom(state(), [
      message("m1"),
      ended(null),
      ended(0),
      // A job can end after a rewind took its call away: kept, and harmless.
      ChatRecord.rewind(messageId: "m1"),
    ]);
    expect(chat.messages, isEmpty);
    expect(chat.jobEndOf("c1"), end(0));
    expect(chat.jobEndOf("c2"), isNull);
  });

  test("a kind of call event this build does not know is kept, and the log "
      "reads on past it", () {
    final records = decodeLog([
      jsonEncode(message("m1").toJson()),
      jsonEncode(const ChatRecord.callEvent(
          callId: "c1", kind: "fromTheFuture", data: {"x": 1}).toJson()),
      jsonEncode(part("m1", 0, "after").toJson()),
    ].join("\n"));
    final chat = chatFrom(state(), records);
    expect(chat.messages.single.parts.single, const MessagePart.text(text: "after"));
    expect(chat.callEvents["c1"], {"fromTheFuture": {"x": 1}});
  });

  test("recordsOf writes a chat out as the log it would have", () {
    final chat = Chat(
      state: ChatState(id: "c1", title: "t", createdAt: at, updatedAt: at),
      messages: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: at,
          parts: const [MessagePart.text(text: "hello")],
        ),
      ],
    );

    expect(replay(recordsOf(chat.messages)), chat.messages);
  });

  test("an author rides the message record and comes back off the log", () {
    final reply = Message(
      id: "m2",
      role: MessageRole.assistant,
      createdAt: at,
      author: "@researcher",
    );
    final records = recordsOf([reply]);

    final back = ChatRecord.fromJson(
        jsonDecode(jsonEncode(records.single.toJson())) as Map<String, dynamic>);
    expect(back, records.single);
    // A message written before this existed reads back unnamed.
    expect(
        replay([
          ChatRecord.message(id: "m3", role: MessageRole.assistant, createdAt: at)
        ]).single.author,
        isNull);
  });

  test("a turn opener's omadaOn survives the round trip and the replay", () {
    final opener = Message(
        id: "m2",
        role: MessageRole.user,
        createdAt: at,
        omadaOn: true);
    final records = [
      message("m1"),
      ...recordsOf([opener]),
    ];

    final back = ChatRecord.fromJson(
        jsonDecode(jsonEncode(records[1].toJson())) as Map<String, dynamic>);
    expect((back as MessageRecord).omadaOn, isTrue);
    expect(replay(records).map((m) => m.omadaOn), [null, true]);
  });

  test("a compaction record rides the round trip and lands on the thread", () {
    final records = [
      message("m1"),
      part("m1", 0, "hello"),
      message("m2", MessageRole.assistant),
      part("m2", 0, "hi"),
      const ChatRecord.compaction(
          upToMessageId: "m2", summary: "The user said hello."),
      message("m3"),
      part("m3", 0, "more"),
    ];
    final round = records
        .map((r) => ChatRecord.fromJson(
            jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>))
        .toList();
    expect(round.lastWhere((r) => r is CompactionRecord), records[4]);

    final chat = chatFrom(state(), records);
    expect(chat.compactions, hasLength(1));
    expect(chat.compactions.single.upToMessageId, "m2");
    expect(chat.compactions.single.summary, "The user said hello.");
  });

  test("a rewind past a compaction boundary un-applies it", () {
    final records = [
      message("m1"),
      message("m2", MessageRole.assistant),
      const ChatRecord.compaction(upToMessageId: "m2", summary: "so far"),
      message("m3"),
      ChatRecord.rewind(messageId: "m2"),
    ];

    // The boundary message is gone, so the marker has nothing to cover and
    // the projection of what is left is the whole conversation again.
    expect(chatFrom(state(), records).compactions, isEmpty);
    expect(replay(records), hasLength(1));
  });

  test("an earlier compaction stays as a shadow beside a newer one", () {
    final records = [
      message("m1"),
      message("m2", MessageRole.assistant),
      const ChatRecord.compaction(upToMessageId: "m2", summary: "first"),
      message("m3"),
      message("m4", MessageRole.assistant),
      const ChatRecord.compaction(upToMessageId: "m4", summary: "second"),
      message("m5"),
    ];

    final chat = chatFrom(state(), records);
    expect(chat.compactions.map((c) => c.summary), ["first", "second"]);
  });

  test("a compaction boundary off the thread being read is not counted", () {
    final records = [
      message("m1"),
      message("m2", MessageRole.assistant),
      branch("m3", of: "m2", role: MessageRole.assistant),
      part("m3", 0, "other thread"),
      const ChatRecord.compaction(upToMessageId: "m2", summary: "so far"),
    ];

    // The thread the log leaves being read runs through m3, the newest — so
    // m2 is a message beside the path, and the marker covering it is not one
    // the thread's projection applies. The user reading m3's thread gets a
    // whole conversation; stepping back to m2's puts the divider back.
    final chat = chatFrom(state(), records);
    expect(chat.compactions, isEmpty);
  });
}
