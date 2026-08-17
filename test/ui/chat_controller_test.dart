import "dart:io";

import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// Give whatever is still in flight a chance to land. The predicate may be
  /// async, since some of what lands has to be read back off disk.
  Future<void> waitFor(FutureOr<bool> Function() done, {String what = "it"}) async {
    for (var i = 0; i < 200; i++) {
      if (await done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail("$what never happened");
  }

  /// send() returns once the prompt is dispatched; the turn ends later, on the
  /// stream's DoneEvent.
  Future<void> waitIdle(String id) => waitFor(
      () => !app.container.read(chatControllerProvider(id)).isRunning,
      what: "the turn");

  /// A chat with a turn under way. The delay lets the controller's initial
  /// load settle before it is driven.
  Future<(String, ChatController)> startTurn(
    String text, {
    List<Attachment> attachments = const [],
  }) async {
    final chat = await app.repo.createChat();
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send(text, attachments: attachments);
    return (id, controller);
  }

  /// A chat holding one finished exchange, plus its controller.
  Future<(String, ChatController)> chatWithOneTurn(
    String text, {
    List<Attachment> attachments = const [],
  }) async {
    final (id, controller) = await startTurn(text, attachments: attachments);
    await waitIdle(id);
    return (id, controller);
  }

  List<Message> messagesOf(String id) => app.container.read(chatControllerProvider(id)).chat!.messages;

  String titleOf(String id) => app.container.read(chatControllerProvider(id)).chat!.state.title;

  String textOf(Message m) => m.parts.whereType<TextPart>().map((p) => p.text).join();

  test("send appends the user message and an assistant reply", () async {
    final (id, _) = await chatWithOneTurn("hello");

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(textOf(messages.first), "hello");
    expect(app.backend.prompts.single.text, "hello");
  });

  group("a new chat", () {
    test("is not on disk until its first message is sent", () async {
      final chat = await app.repo.createChat();
      expect(File(app.config.stateFile(chat.state.id)).existsSync(), isFalse);
      expect(await app.repo.listChats(), isEmpty);

      final controller = app.container.read(chatControllerProvider(chat.state.id).notifier);
      await Future<void>.delayed(Duration.zero);
      await controller.send("hello");
      await waitIdle(chat.state.id);

      expect(await app.repo.listChats(), hasLength(1));
    });

    test("keeps the name it was made with when no title model is set", () async {
      app.backend.scriptedAnswer = "A better name";
      final (id, _) = await chatWithOneTurn("hello");

      expect(app.backend.questions, isEmpty);
      expect((await app.repo.openChat(id)).state.title, "New chat");
    });

    test("is named by the title model from its first message", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = "Sorting a list of records";
      final (id, _) = await chatWithOneTurn("how do I sort a list?");
      await waitFor(() => titleOf(id) != "New chat", what: "the title");
      // On disk, not just on screen: the name is applied before it is written,
      // and the turn ending no longer writes `state.json` on its way past.
      await waitFor(
          () async => (await app.repo.openChat(id)).state.title != "New chat",
          what: "the title reaching disk");

      expect(app.backend.questions.single.prompt, contains("how do I sort a list?"));
      expect((await app.repo.openChat(id)).state.title, "Sorting a list of records");
    });

    test("is named once, not again on every message", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = "The first thing asked";
      final (id, controller) = await chatWithOneTurn("first");
      await controller.send("second");
      await waitIdle(id);

      expect(app.backend.questions, hasLength(1));
    });

    test("a title model that answers nothing leaves the name alone", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = null;
      final (id, _) = await chatWithOneTurn("hello");
      await waitFor(() => app.backend.questions.isNotEmpty, what: "the title call");

      expect(titleOf(id), "New chat");
      expect((await app.repo.openChat(id)).state.title, "New chat");
    });
  });

  test("thinking is kept out of the reply", () async {
    app.backend.scriptedEvents = const [
      ReasoningDelta("let me"),
      ReasoningDelta(" work it out"),
      ReasoningEnd(text: "let me work it out", duration: Duration(seconds: 3)),
      TextDelta("391"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("17*23?");

    final reply = messagesOf(id).last;
    expect(textOf(reply), "391");
    final thinking = reply.parts.whereType<ReasoningPart>().single;
    expect(thinking.text, "let me work it out");
    expect(thinking.durationMs, 3000);
  });

  test("a block the backend only reports whole still lands", () async {
    // A provider that streams no reasoning deltas: the closing event carries
    // the lot.
    app.backend.scriptedEvents = const [
      ReasoningEnd(text: "thought about it", duration: Duration(seconds: 1)),
      TextDelta("done"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    expect(messagesOf(id).last.parts.whereType<ReasoningPart>().single.text, "thought about it");
  });

  test("thinking either side of a tool call stays in two blocks", () async {
    app.backend.scriptedEvents = const [
      ReasoningDelta("first"),
      ReasoningEnd(text: "first", duration: Duration(seconds: 1)),
      ToolCallEvent(ToolCall(id: "c1", name: "bash")),
      ToolResultEvent(ToolResult(callId: "c1", returnCode: 0, output: "ok")),
      ReasoningDelta("second"),
      ReasoningEnd(text: "second", duration: Duration(seconds: 2)),
      TextDelta("all done"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final parts = messagesOf(id).last.parts;
    expect(parts.whereType<ReasoningPart>().map((p) => p.text), ["first", "second"]);
    expect(parts.map((p) => p.runtimeType.toString()), [
      "ReasoningPart",
      "ToolCallPart",
      "ToolResultPart",
      "ReasoningPart",
      "TextPart",
    ]);
  });

  // A provider that interleaves parts closes the block after the tool it
  // started. The block is still the one being written, wherever it sits.
  test("a block interrupted by a tool call is closed, not written twice", () async {
    app.backend.scriptedEvents = const [
      ReasoningDelta("I should check"),
      ToolCallEvent(ToolCall(id: "c1", name: "bash")),
      ToolResultEvent(ToolResult(callId: "c1", returnCode: 0, output: "ok")),
      ReasoningEnd(text: "I should check", duration: Duration(seconds: 4)),
      TextDelta("checked"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final parts = messagesOf(id).last.parts;
    final thinking = parts.whereType<ReasoningPart>().single;
    expect(thinking.text, "I should check");
    expect(thinking.durationMs, 4000);
    expect(parts.first, isA<ReasoningPart>());
  });

  test("thinking is persisted with the conversation", () async {
    app.backend.scriptedEvents = const [
      ReasoningDelta("hmm"),
      ReasoningEnd(text: "hmm", duration: Duration(seconds: 2)),
      TextDelta("hi"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ReasoningPart>().single.durationMs, 2000);
  });

  test("thinking is not resent as context on a rewind", () async {
    app.backend.scriptedEvents = const [
      ReasoningEnd(text: "my private notes", duration: Duration(seconds: 1)),
      TextDelta("first answer"),
      DoneEvent(),
    ];
    final (id, controller) = await chatWithOneTurn("first");
    await controller.send("second");
    await waitIdle(id);

    await controller.regenerate(messagesOf(id)[2].id);
    await waitIdle(id);

    final seeded = app.backend.resets.single.map((m) => m.plainText).join("\n");
    expect(seeded, contains("first answer"));
    expect(seeded, isNot(contains("my private notes")));
  });

  test("a backend error becomes an error part on the reply", () async {
    app.backend.scriptedEvents = const [ErrorEvent("APIError (HTTP 429): usage limit"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    final reply = messagesOf(id).last;
    expect(reply.role, MessageRole.assistant);
    expect(reply.parts.whereType<ErrorPart>().single.message, contains("usage limit"));
    expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
  });

  test("a retry shows up as a notice while the turn is still running", () async {
    app.backend.scriptedEvents = const [
      RetryEvent(attempt: 2, message: "you have reached your session usage limit"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final view = app.container.read(chatControllerProvider(id));
    expect(view.retry, contains("usage limit"));
    expect(view.retry, contains("Attempt 2"));
    expect(view.isRunning, isTrue);
    app.backend.hold!.complete();
  });

  test("the retry notice is dropped once the turn ends", () async {
    app.backend.scriptedEvents = const [
      RetryEvent(attempt: 1, message: "rate limited"),
      ErrorEvent("APIError (HTTP 429): rate limited"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final view = app.container.read(chatControllerProvider(id));
    expect(view.retry, isNull);
    expect(view.chat!.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
  });

  test("a retry is never written to the conversation", () async {
    app.backend.scriptedEvents = const [
      RetryEvent(attempt: 1, message: "rate limited"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts, isEmpty);
  });

  test("an errored reply is persisted with the chat", () async {
    app.backend.scriptedEvents = const [ErrorEvent("APIError (HTTP 429): usage limit"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
  });

  test("regenerate resends the same text as another thread", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final userId = messagesOf(id).first.id;

    await controller.regenerate(userId);
    await waitIdle(id);

    expect(messagesOf(id), hasLength(2));
    expect(app.backend.prompts.map((p) => p.text), ["hello", "hello"]);
  });

  test("regenerate from the assistant reply reruns the message above it", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final assistantId = messagesOf(id).last.id;

    await controller.regenerate(assistantId);
    await waitIdle(id);

    expect(app.backend.prompts.map((p) => p.text), ["hello", "hello"]);
    expect(messagesOf(id), hasLength(2));
  });

  test("editAndResend replaces the message text", () async {
    final (id, controller) = await chatWithOneTurn("helo");
    final userId = messagesOf(id).first.id;

    await controller.editAndResend(userId, "hello");
    await waitIdle(id);

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(textOf(messages.first), "hello");
    expect(app.backend.prompts.map((p) => p.text), ["helo", "hello"]);
  });

  test("a resend starts a fresh session seeded with the kept messages", () async {
    final (id, controller) = await chatWithOneTurn("first");
    await controller.send("second");
    await waitIdle(id);
    final secondId = messagesOf(id)[2].id;

    await controller.regenerate(secondId);
    await waitIdle(id);

    expect(app.backend.resets, hasLength(1));
    final seeded = app.backend.resets.single.map((m) => m.plainText);
    expect(seeded, contains("first"));
    expect(seeded, isNot(contains("second")));
  });

  // A session lives in memory, so a chat opened after a restart has none. The
  // conversation travels with the prompt rather than the backend being left to
  // answer it from nothing.
  test("every prompt carries what came before it", () async {
    final (id, controller) = await chatWithOneTurn("first");
    await controller.send("second");
    await waitIdle(id);

    expect(app.backend.prompts, hasLength(2));
    expect(app.backend.prompts.first.history, isEmpty);
    expect(app.backend.prompts.last.history.map((m) => m.plainText), contains("first"));
  });

  test("an attachment is saved, recorded on the message and sent with it", () async {
    final (id, _) = await chatWithOneTurn(
      "look",
      attachments: [testAttachment("shot.png", mimeType: "image/png")],
    );

    final file = (await app.repo.openChat(id)).messages.first.parts.whereType<FilePart>().single;
    expect(file.filename, "shot.png");
    expect(file.mimeType, "image/png");
    expect(Directory(app.config.resourcesDir(id)).listSync(), hasLength(1));
    expect(app.backend.prompts.single.attachments.single.bytes, [104, 105]);
  });

  test("regenerating sends the attachments again, from disk", () async {
    final (id, controller) = await chatWithOneTurn(
      "look",
      attachments: [testAttachment("shot.png", mimeType: "image/png")],
    );

    await controller.regenerate(messagesOf(id).first.id);
    await waitIdle(id);

    expect(app.backend.prompts.map((p) => p.attachments.single.filename), ["shot.png", "shot.png"]);
    expect(messagesOf(id).first.parts.whereType<FilePart>(), hasLength(1));
    // The same file, not a second copy of it.
    expect(Directory(app.config.resourcesDir(id)).listSync(), hasLength(1));
  });

  test("editing the text keeps what the message carried", () async {
    final (id, controller) = await chatWithOneTurn(
      "look",
      attachments: [testAttachment("notes.txt")],
    );

    await controller.editAndResend(messagesOf(id).first.id, "read this");
    await waitIdle(id);

    final message = (await app.repo.openChat(id)).messages.first;
    expect(textOf(message), "read this");
    expect(message.parts.whereType<FilePart>().single.filename, "notes.txt");
    expect(app.backend.prompts.last.attachments.single.filename, "notes.txt");
  });

  test("the branched conversation is persisted, not just held in memory", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final userId = messagesOf(id).first.id;

    await controller.editAndResend(userId, "goodbye");
    await waitIdle(id);

    final stored = await app.repo.openChat(id);
    expect(stored.messages, hasLength(2));
    expect(textOf(stored.messages.first), "goodbye");
  });

  group("threads", () {
    /// A chat whose one prompt has two replies: the first, and a regenerate
    /// beside it. Hands back the ids of both, oldest first.
    Future<(String, ChatController, String, String)> twoReplies() async {
      app.backend.scriptedEvents = const [TextDelta("first answer"), DoneEvent()];
      final (id, controller) = await chatWithOneTurn("hello");
      final first = messagesOf(id).last.id;

      app.backend.scriptedEvents = const [TextDelta("second answer"), DoneEvent()];
      await controller.regenerate(first);
      await waitIdle(id);
      return (id, controller, first, messagesOf(id).last.id);
    }

    test("regenerate puts the reply beside the old one, and keeps the prompt", () async {
      final (id, _, first, second) = await twoReplies();

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      expect(chat.messages, hasLength(2));
      expect(textOf(chat.messages.last), "second answer");
      expect(chat.threadsAt(second), [first, second]);
      expect(chat.threadIndex(second), 1);
      // The prompt is the branch point rather than something written again, so
      // the counter is under the reply and there is nothing under the prompt.
      expect(chat.threadsAt(chat.messages.first.id), [chat.messages.first.id]);
    });

    test("an edit puts the new prompt beside the old one", () async {
      final (id, controller) = await chatWithOneTurn("helo");
      final first = messagesOf(id).first.id;

      await controller.editAndResend(first, "hello");
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      expect(chat.messages, hasLength(2));
      expect(textOf(chat.messages.first), "hello");
      expect(chat.threadsAt(chat.messages.first.id), [first, chat.messages.first.id]);
    });

    test("stepping back reads the thread that was replaced", () async {
      final (id, controller, first, second) = await twoReplies();

      await controller.stepThread(second, -1);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      expect(textOf(chat.messages.last), "first answer");
      expect(chat.threadIndex(first), 0);
      // Which thread was being read survives a reload, since it is a record.
      expect(textOf((await app.repo.openChat(id)).messages.last), "first answer");
    });

    test("stepping back and on again comes back to the newer thread", () async {
      final (id, controller, first, second) = await twoReplies();

      await controller.stepThread(second, -1);
      await controller.stepThread(first, 1);

      expect(textOf(messagesOf(id).last), "second answer");
    });

    test("moving between threads gives the model the one being read", () async {
      final (id, controller, _, second) = await twoReplies();
      app.backend.resets.clear();

      await controller.stepThread(second, -1);

      expect(app.backend.resets.single.map((m) => m.plainText), contains("first answer"));
    });

    test("deleting a thread leaves the one beside it", () async {
      final (id, controller, _, second) = await twoReplies();

      await controller.deleteThread(second);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      expect(textOf(chat.messages.last), "first answer");
      expect(chat.branches, isEmpty);
      expect((await app.repo.openChat(id)).messages, hasLength(2));
    });

    test("deleting the last thread cuts the conversation off there", () async {
      final (id, controller) = await chatWithOneTurn("hello");

      await controller.deleteThread(messagesOf(id).last.id);

      expect(messagesOf(id), hasLength(1));
      expect((await app.repo.openChat(id)).messages, hasLength(1));
    });

    /// A turn the user stopped before the model said anything, which is what
    /// leaves an empty reply on the end of the conversation.
    Future<(String, ChatController)> chatWithNothingSaid() async {
      app.backend.scriptedEvents = const [DoneEvent(aborted: true)];
      final (id, controller) = await chatWithOneTurn("hello");
      expect(messagesOf(id).last.parts, isEmpty);
      app.backend.scriptedEvents = const [TextDelta("an answer"), DoneEvent()];
      return (id, controller);
    }

    test("a turn that said nothing is replaced rather than kept beside", () async {
      final (id, controller) = await chatWithNothingSaid();

      await controller.regenerate(messagesOf(id).last.id);
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      expect(chat.messages.map(textOf), ["hello", "an answer"]);
      // No counter to press: the thread it replaced offered a blank page.
      expect(chat.branches, isEmpty);
      expect((await app.repo.openChat(id)).branches, isEmpty);
    });

    // The reason the rewind is written after the message replacing it: the new
    // thread has to name one of the siblings while they are all still there, or
    // it lands under whichever was left rather than beside them.
    test("replacing an empty thread leaves the ones beside it alone", () async {
      final (id, controller, first, second) = await twoReplies();
      app.backend.scriptedEvents = const [DoneEvent(aborted: true)];
      await controller.regenerate(second);
      await waitIdle(id);
      final empty = messagesOf(id).last.id;
      expect(messagesOf(id).last.parts, isEmpty);

      app.backend.scriptedEvents = const [TextDelta("third answer"), DoneEvent()];
      await controller.regenerate(empty);
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final third = chat.messages.last.id;
      expect(textOf(chat.messages.last), "third answer");
      expect(chat.threadsAt(third), [first, second, third]);
      expect((await app.repo.openChat(id)).branches, chat.branches);
    });

    test("a turn that said nothing but was written under is kept", () async {
      final (id, controller) = await chatWithNothingSaid();
      final empty = messagesOf(id).last.id;
      await controller.send("are you there?");
      await waitIdle(id);

      await controller.regenerate(empty);
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      // The reply stayed empty, but a conversation happened under it and that
      // is not something to delete for the sake of a counter.
      expect(chat.threadsAt(chat.messages.last.id), [empty, chat.messages.last.id]);
    });

    test("regenerating an older thread joins them rather than nesting", () async {
      final (id, controller, first, second) = await twoReplies();
      await controller.stepThread(second, -1);

      app.backend.scriptedEvents = const [TextDelta("third answer"), DoneEvent()];
      await controller.regenerate(first);
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final third = chat.messages.last.id;
      expect(textOf(chat.messages.last), "third answer");
      expect(chat.threadsAt(third), [first, second, third]);
      expect(chat.threadIndex(third), 2);
    });

    test("carrying on from an older thread adds to that one", () async {
      final (id, controller, _, second) = await twoReplies();
      await controller.stepThread(second, -1);

      app.backend.scriptedEvents = const [TextDelta("and then"), DoneEvent()];
      await controller.send("go on");
      await waitIdle(id);

      final messages = messagesOf(id).map(textOf);
      expect(messages, ["hello", "first answer", "go on", "and then"]);
      expect((await app.repo.openChat(id)).messages.map(textOf), messages);
    });
  });

  group("the log", () {
    late FakeChatStore store;

    // Over a fake store rather than a temp directory: what these check is which
    // records a turn wrote, which no filesystem is needed to answer — and
    // reading one back meant polling it, which is how they flaked.
    setUp(() {
      store = FakeChatStore();
      app.dispose();
      app = TestApp.create(store: store);
    });

    List<ChatRecord> records(String id) => store.records(id);

    /// The chat as a reload would find it, rather than as the controller holds
    /// it. The two have to agree, which is the point of most of these.
    List<Message> reloaded(String id) => replay(store.records(id));

    // The one that pins the live path to the replay path: what the controller
    // built as events arrived, and what replay makes of the records it wrote,
    // are the same conversation. Anything that appends to a message without
    // logging it breaks here.
    test("what is on screen is what a reload reads back", () async {
      app.backend.scriptedEvents = [
        const ReasoningDelta("weighing it up"),
        ReasoningEnd(text: "weighing it up", duration: const Duration(seconds: 2)),
        const TextDelta("running it"),
        ToolCallEvent(ToolCall(id: "t1", name: "bash", argumentsJson: '{"command":"ls"}')),
        ToolResultEvent(ToolResult(callId: "t1", returnCode: 0, output: "a\nb")),
        const TextDelta("two files"),
        const DoneEvent(),
      ];

      final (id, _) = await chatWithOneTurn("what is here");

      expect(reloaded(id), messagesOf(id));
    });

    // What lets the turn be handed back to a provider a response at a time —
    // the reasoning block and the call it preceded have to stay together.
    test("parts are stamped with the response they came out of", () async {
      app.backend.scriptedEvents = [
        const ResponseStart("r1"),
        const ReasoningDelta("have a look"),
        const ReasoningEnd(duration: Duration(seconds: 1), signature: "sig-1"),
        ToolCallEvent(ToolCall(id: "t1", name: "bash", argumentsJson: '{"command":"ls"}')),
        ToolResultEvent(ToolResult(callId: "t1", returnCode: 0, output: "a")),
        const ResponseStart("r2"),
        const TextDelta("one file"),
        const DoneEvent(),
      ];

      final (id, _) = await chatWithOneTurn("what is here");

      final parts = reloaded(id).last.parts;
      final thinking = parts.whereType<ReasoningPart>().single;
      expect(thinking.responseId, "r1");
      expect(thinking.signature, "sig-1");
      expect(parts.whereType<ToolCallPart>().single.responseId, "r1");
      expect(parts.whereType<TextPart>().single.responseId, "r2");
    });

    test("text from two responses is kept as two parts", () async {
      app.backend.scriptedEvents = const [
        ResponseStart("r1"),
        TextDelta("running it"),
        ResponseStart("r2"),
        TextDelta("done"),
        DoneEvent(),
      ];

      final (id, _) = await chatWithOneTurn("go");

      expect(
          reloaded(id).last.parts.whereType<TextPart>().map((p) => (p.text, p.responseId)),
          [("running it", "r1"), ("done", "r2")]);
    });

    test("a turn killed mid-flight keeps what had already happened", () async {
      app.backend.hold = Completer<void>();
      app.backend.scriptedEvents = [
        const TextDelta("looking"),
        ToolCallEvent(ToolCall(id: "t1", name: "bash", argumentsJson: '{"command":"ls"}')),
        ToolResultEvent(ToolResult(callId: "t1", returnCode: 0, output: "a\nb")),
      ];

      final (id, _) = await startTurn("what is here");
      await waitFor(
          () => reloaded(id).last.parts.whereType<ToolResultPart>().isNotEmpty,
          what: "the tool result reaching the log");

      // Nothing has ended the turn, which is exactly the state a kill leaves.
      final stored = reloaded(id);
      expect(stored, hasLength(2));
      expect(stored.last.parts.whereType<ToolResultPart>().single.result.output, "a\nb");
      expect(records(id).whereType<TurnEndRecord>(), isEmpty);

      app.backend.hold!.complete();
      await waitIdle(id);
    });

    test("a finished turn is closed with why it ended", () async {
      final (id, _) = await chatWithOneTurn("hello");

      expect(records(id).last, isA<TurnEndRecord>()
          .having((r) => r.reason, "reason", TurnEnd.done));
    });

    test("a turn the user stops is closed as aborted, not as an error", () async {
      app.backend.hold = Completer<void>();
      final (id, controller) = await startTurn("hello");
      await controller.abort();

      expect(records(id).last, isA<TurnEndRecord>()
          .having((r) => r.reason, "reason", TurnEnd.aborted));
      app.backend.hold!.complete();
    });

    test("a turn that failed is closed as an error", () async {
      app.backend.scriptedEvents = const [ErrorEvent("nope"), DoneEvent()];
      final (id, _) = await chatWithOneTurn("hello");

      expect(records(id).last, isA<TurnEndRecord>()
          .having((r) => r.reason, "reason", TurnEnd.error));
    });

    test("a branch is written as a record, and the log is only added to", () async {
      final (id, controller) = await chatWithOneTurn("hello");
      final before = [...records(id)];
      final userId = messagesOf(id).first.id;

      await controller.editAndResend(userId, "goodbye");
      await waitIdle(id);

      final after = records(id);
      expect(after.take(before.length), before);
      expect(after.length, greaterThan(before.length));
      // The thread it replaces is still readable, so nothing was forgotten.
      expect(after.whereType<RewindRecord>(), isEmpty);
      expect(after.whereType<MessageRecord>().map((r) => r.siblingOf).nonNulls,
          [userId]);
      expect(reloaded(id), messagesOf(id));
    });

    test("what a branch puts on screen is what a reload reads back", () async {
      final (id, controller) = await chatWithOneTurn("hello");
      await controller.regenerate(messagesOf(id).last.id);
      await waitIdle(id);

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final reload = chatFrom(chat.state, records(id));
      expect(reload.messages, chat.messages);
      expect(reload.branches, chat.branches);
    });

    group("carrying on an interrupted turn", () {
      final at = DateTime.utc(2026, 1, 1);

      /// A chat put in the store as a killed process would have left it: a
      /// prompt, a reply holding a command nothing answered, and no record
      /// closing the turn. Nothing the controller does starts before the
      /// reload, so there is no turn to run to get here.
      Future<(String, ChatController)> killedChat() async {
        const id = "killed";
        await writeChatTo(
          store,
          Chat(
            state: ChatState(id: id, title: "t", createdAt: at, updatedAt: at),
            messages: [
              Message(id: "m1", role: MessageRole.user, createdAt: at, parts: const [
                MessagePart.text(text: "count the files"),
              ]),
              Message(id: "m2", role: MessageRole.assistant, createdAt: at, parts: const [
                MessagePart.toolCall(
                    toolCall:
                        ToolCall(id: "c1", name: "bash", argumentsJson: '{"command":"ls"}')),
              ]),
            ],
          ),
          finished: false,
        );
        final controller = app.container.read(chatControllerProvider(id).notifier);
        await waitFor(() => app.container.read(chatControllerProvider(id)).chat != null,
            what: "the chat loading");
        return (id, controller);
      }

      bool offeredIn(String id) =>
          app.container.read(chatControllerProvider(id)).chat!.unfinished;

      test("a reply nothing closed is offered", () async {
        final (id, _) = await killedChat();
        expect(offeredIn(id), isTrue);
      });

      // The whole point of resuming rather than regenerating: the command that
      // did run stays where it is, and the answer lands under it.
      test("what it produces goes on the end of the same reply", () async {
        app.backend.scriptedEvents = const [
          ResponseStart("r9"),
          TextDelta("two files"),
          DoneEvent(),
        ];
        final (id, controller) = await killedChat();
        final opened = records(id).whereType<MessageRecord>().length;

        await controller.resume();
        await waitIdle(id);

        expect(records(id).whereType<MessageRecord>(), hasLength(opened));
        final messages = reloaded(id);
        expect(messages, hasLength(2));
        expect(messages.last.parts.first, isA<ToolCallPart>());
        expect(messages.last.parts.whereType<TextPart>().single.text, "two files");
        expect(messages, messagesOf(id));
      });

      test("the turn is closed when it finishes this time", () async {
        final (id, controller) = await killedChat();
        await controller.resume();
        await waitIdle(id);

        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", TurnEnd.done));
        expect(offeredIn(id), isFalse);
      });

      // The reply already holds the ErrorPart the first attempt left in it, so
      // a turn whose outcome was read back off the parts would close as an
      // error again and go on being offered for ever.
      test("carrying on a turn that gave up closes it as done", () async {
        final (id, controller) = await killedChat();
        app.backend.scriptedEvents = const [ErrorEvent("nope"), DoneEvent()];
        await controller.resume();
        await waitIdle(id);

        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", TurnEnd.error));

        app.backend.scriptedEvents = const [TextDelta("two files"), DoneEvent()];
        await controller.resume();
        await waitIdle(id);

        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", TurnEnd.done));
      });

      test("the backend is given the turn it is carrying on", () async {
        final (id, controller) = await killedChat();
        await controller.resume();
        await waitIdle(id);

        expect(app.backend.prompts, isEmpty);
        expect(app.backend.resumes.single.history.map((m) => m.id), ["m1", "m2"]);
      });
    });
  });
}

/// Settings with chat naming turned on. A getter, not a constant: settings are
/// mutable and each test writes its own copy.
AppSettings get _withTitleModel =>
    AppSettings(titleProviderId: "anthropic", titleModelId: "claude-haiku-3");
