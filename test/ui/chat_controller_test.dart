import "dart:io";

import "dart:async";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/end_turn.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/project_settings.dart"
    show OmadaOrdering, ProjectSettings;
import "package:agent_chat/domain/prompt_library.dart"
    show PromptDocument, PromptLibrary;
import "package:agent_chat/providers.dart"
    show
        appSettingsProvider,
        projectSettingsProvider,
        promptLibraryProvider;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/trigger_turn_driver.dart";
import "package:agent_chat/ui/chat/chat_page.dart"
    show CompactionEntry, entriesOf, MessageEntry, SectionEntry;

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// send() returns once the prompt is dispatched; the turn ends later, on the
  /// stream's DoneEvent. Retry rounds wait out real backoff between them, so a
  /// caller expecting rounds names a limit that covers the waits. [target] is
  /// the app whose container to read — a test may hold more than one.
  Future<void> waitIdle(String id,
          {Duration limit = const Duration(seconds: 2), TestApp? target}) =>
      waitFor(
          () => !(target ?? app)
              .container
              .read(chatControllerProvider(id))
              .isRunning,
          what: "the turn", limit: limit);

  /// A chat with a turn under way. Nothing waits for the controller to have
  /// read the chat back: `send` waits on that itself, which is what lets the
  /// app drive a controller it built in the same breath.
  Future<(String, ChatController)> startTurn(
    String text, {
    List<Attachment> attachments = const [],
    String? project,
  }) async {
    final chat = await app.repo.createChat(project: project);
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await controller.send(text, attachments: attachments);
    return (id, controller);
  }

  /// A chat holding one finished exchange, plus its controller.
  Future<(String, ChatController)> chatWithOneTurn(
    String text, {
    List<Attachment> attachments = const [],
    String? project,
  }) async {
    final (id, controller) =
        await startTurn(text, attachments: attachments, project: project);
    await waitIdle(id);
    return (id, controller);
  }

  ChatViewState viewOf(String id) => app.container.read(chatControllerProvider(id));

  Chat chatOf(String id) => viewOf(id).chat!;

  List<Message> messagesOf(String id) => chatOf(id).messages;

  String titleOf(String id) => chatOf(id).state.title;

  String textOf(Message m) => m.parts.whereType<TextPart>().map((p) => p.text).join();

  test("send appends the user message and an assistant reply", () async {
    final (id, _) = await chatWithOneTurn("hello");

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(textOf(messages.first), "hello");
    expect(app.backend.prompts.single.prompt.plainText, "hello");
    // Under the date it was logged with, not the clock: what the model is shown
    // of a user turn carries the moment it was sent, so a turn rebuilt from the
    // log has to land on the same string. See `userTurnText`.
    expect(app.backend.prompts.single.prompt.createdAt, messages.first.createdAt);
  });

  group("a new chat", () {
    /// The name is applied on screen before it is written, and the turn ending
    /// no longer writes `state.json` on its way past — so a test reading the
    /// name off disk has to wait for it separately.
    Future<void> waitForNameOnDisk(String id) => waitFor(
        () async => (await app.repo.openChat(id)).state.title != "New chat",
        what: "the title reaching disk");

    // Creating one writes it, so what keeps an untouched chat off the disk is
    // that nothing creates one until there is something to say — see "Nothing
    // selected is a new chat" for where that decision now lives.
    test("is on disk from the moment it is made", () async {
      final chat = await app.repo.createChat();

      expect(File(app.config.stateFile(chat.state.id)).existsSync(), isTrue);
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
      await waitForNameOnDisk(id);

      expect(app.backend.questions.single.prompt, contains("how do I sort a list?"));
      expect((await app.repo.openChat(id)).state.title, "Sorting a list of records");
    });

    test("is named once, not again on every message", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = "The first thing asked";
      final (id, controller) = await chatWithOneTurn("first");
      // Naming runs beside the turn rather than in it, so it is waited for here
      // rather than left to land after the directory is torn down.
      await waitForNameOnDisk(id);
      await controller.send("second");
      await waitIdle(id);

      expect(app.backend.questions, hasLength(1));
    });

    // A model call on the one turn the user routed away from a model, in a chat
    // that may have no provider at all.
    test("a chat opened with a command asks no model to name it", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = "Listing the files";
      final (id, _) = await chatWithOneTurn("!ls");

      expect(app.backend.questions, isEmpty);
      expect(titleOf(id), "New chat");
    });

    test("a title model that answers nothing leaves the name alone", () async {
      app.seedSettings(_withTitleModel);
      app.backend.scriptedAnswer = null;
      final (id, _) = await chatWithOneTurn("hello");
      await waitFor(() => app.backend.questions.isNotEmpty, what: "the title call");

      expect(titleOf(id), "New chat");
      expect((await app.repo.openChat(id)).state.title, "New chat");
    });

    // Naming happens on the same turn that first anchors a temporary chat, and
    // used to write the state from before it back — leaving the chat with a TTL
    // and nothing to count from, on disk and in the bar both.
    test("naming a temporary chat keeps its countdown", () async {
      app.seedSettings(_withTitleModel..tempChatTtl = TempChatTtl.hours24);
      app.backend.scriptedAnswer = "Saying hello";
      final (id, _) = await chatWithOneTurn("hello");
      await waitForNameOnDisk(id);

      expect((await app.repo.openChat(id)).state.tempTtlExpiresAt, isNotNull);
      expect(chatOf(id).state.tempTtlExpiresAt, isNotNull);
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
    // And what the conversation keeps agrees with what was on screen.
    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ReasoningPart>().single.durationMs,
        3000);
  });

  test("the turn's newest context is on the reply, and on the log", () async {
    app.backend.scriptedEvents = const [
      ContextEvent(ContextUsage(system: 1, tools: 2, profile: 0, chat: 3)),
      ContextEvent(ContextUsage(system: 1, tools: 2, profile: 0, chat: 9, reported: 20)),
      TextDelta("hi"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    expect(messagesOf(id).last.context?.chat, 9);
    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.context?.reported, 20);
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

  test("a command the user ran is the whole of its turn, and is persisted", () async {
    app.backend.scriptedEvents = const [
      ShellRunEvent(
          ShellRunPart(command: "echo hello", returnCode: 0, output: "hello\n")),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("!echo hello");

    final reply = messagesOf(id).last;
    expect(reply.parts.single, isA<ShellRunPart>());
    final stored = (await app.repo.openChat(id)).messages.last;
    expect(stored.parts, reply.parts);
  });

  test("a backend error becomes an error part on the reply", () async {
    app.backend.scriptedEvents = const [ErrorEvent("APIError (HTTP 429): usage limit"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    final reply = messagesOf(id).last;
    expect(reply.role, MessageRole.assistant);
    expect(reply.parts.whereType<ErrorPart>().single.message, contains("usage limit"));
    expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
    // Every message is answered by the main agent, and its phase is open once
    // the turn is over — the room's two facts, pinned at one of the seams.
    expect(app.container.read(chatControllerProvider(id)).roomPhase,
        RoomPhase.open);
    // And the errored reply is persisted with the chat.
    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
  });

  test("an error's stack trace is kept in the log", () async {
    app.backend.scriptedEvents = const [
      ErrorEvent("RangeError", trace: "#0 main (file.dart:1)"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ErrorPart>().single.trace,
        "#0 main (file.dart:1)");
  });

  test("the reply starting is what takes the status away", () async {
    app.backend.scriptedEvents = const [
      StatusEvent("Thinking"),
      StatusEvent(null),
      TextDelta("here you go"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    // Poll the positive first: a wait for status to be null would pass before
    // any event is processed and stop pinning the behaviour.
    await waitFor(() => textOf(messagesOf(id).last).isNotEmpty,
        what: "the reply to start");

    // From here the caret says the turn is alive, and a label beside it would
    // be the second thing saying so.
    expect(app.container.read(chatControllerProvider(id)).status, isNull);
    app.backend.hold!.complete();
  });

  test("the call's result is what takes the output away", () async {
    app.backend.scriptedEvents = const [
      ToolCallEvent(ToolCall(id: "c1", name: "bash", argumentsText: "ls")),
      ShellOutputEvent(callId: "c1", text: "files\n"),
      ToolResultEvent(ToolResult(callId: "c1", returnCode: 0, output: "files\n")),
    ];
    final (id, _) = await chatWithOneTurn("run it");

    final view = app.container.read(chatControllerProvider(id));
    expect(view.shellOutput, isEmpty);
    // What the conversation keeps is the pair, and the pair's output.
    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ToolCallPart>(), hasLength(1));
    expect(
        stored.messages.last.parts.whereType<ToolResultPart>().single.result.output,
        "files\n");
  });

  // Turn-scoped view state: held while the turn runs, the latest replacing the
  // last since each is one row, gone when the turn ends, and never written.
  final transients = <(String, List<AgentEvent>, String? Function(ChatViewState), String)>[
    (
      "retry notice",
      const [
        RetryEvent(attempt: 1, message: "rate limited"),
        RetryEvent(attempt: 2, message: "usage limit"),
      ],
      (v) => v.retry,
      "Attempt 2 failed: usage limit",
    ),
    (
      "status",
      const [StatusEvent("Thinking"), StatusEvent("Reading the prompt · 43%")],
      (v) => v.status,
      "Reading the prompt · 43%",
    ),
    (
      "command output",
      const [
        ShellOutputEvent(callId: "c1", text: "line one\n"),
        ShellOutputEvent(callId: "c1", text: "line one\nline two\n"),
      ],
      (v) => v.shellOutput[v.chat?.messages.last.id],
      "line one\nline two\n",
    ),
  ];
  for (final (name, events, read, latest) in transients) {
    test("the $name is held while the turn runs, and only then", () async {
      app.backend.scriptedEvents = events;
      app.backend.hold = Completer<void>();
      final (id, _) = await startTurn("hello");
      await waitFor(() => read(viewOf(id)) == latest, what: "the $name");
      expect(viewOf(id).isRunning, isTrue);

      app.backend.hold!.complete();
      await waitIdle(id);
      expect(read(viewOf(id)), isNull);
      expect((await app.repo.openChat(id)).messages.last.parts, isEmpty);
    });
  }

  test("regenerate from either side reruns the prompt as another thread",
      () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final sentAt = messagesOf(id).first.createdAt;

    await controller.regenerate(messagesOf(id).first.id);
    await waitIdle(id);
    await controller.regenerate(messagesOf(id).last.id);
    await waitIdle(id);

    expect(messagesOf(id), hasLength(2));
    expect(messagesOf(id).last.role, MessageRole.assistant);
    expect(app.backend.prompts.map((p) => p.prompt.plainText),
        ["hello", "hello", "hello"]);
    // The same date too: a regenerate re-runs the logged message, so the
    // model is shown the same string.
    expect(app.backend.prompts.map((p) => p.prompt.createdAt),
        [sentAt, sentAt, sentAt]);
  });

  test("a resend seeds a fresh session with what was said, not thought",
      () async {
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

    final seeded = app.backend.resets.single.map((m) => m.plainText);
    expect(seeded, containsAll(["first", "first answer"]));
    expect(seeded, isNot(contains("second")));
    expect(seeded.join("\n"), isNot(contains("my private notes")));
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
    expect(app.backend.prompts.single.prompt.files.single.filename, "shot.png");
    expect(await app.repo.readResource(id, file.resource), [104, 105]);
  });

  test("regenerating sends the attachments again, from disk", () async {
    final (id, controller) = await chatWithOneTurn(
      "look",
      attachments: [testAttachment("shot.png", mimeType: "image/png")],
    );

    await controller.regenerate(messagesOf(id).first.id);
    await waitIdle(id);

    expect(app.backend.prompts.map((p) => p.prompt.files.single.filename), ["shot.png", "shot.png"]);
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
    expect(app.backend.prompts.last.prompt.files.single.filename, "notes.txt");
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

      final chat = chatOf(id);
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

      final chat = chatOf(id);
      expect(chat.messages, hasLength(2));
      expect(textOf(chat.messages.first), "hello");
      expect(chat.threadsAt(chat.messages.first.id), [first, chat.messages.first.id]);
      expect(app.backend.prompts.map((p) => p.prompt.plainText), ["helo", "hello"]);
      expect((await app.repo.openChat(id)).messages.map(textOf),
          chat.messages.map(textOf));
    });

    test("stepping back reads the thread that was replaced, and on comes back",
        () async {
      final (id, controller, first, second) = await twoReplies();

      await controller.stepThread(second, -1);

      final chat = chatOf(id);
      expect(textOf(chat.messages.last), "first answer");
      expect(chat.threadIndex(first), 0);
      // Which thread was being read survives a reload, since it is a record.
      expect(textOf((await app.repo.openChat(id)).messages.last), "first answer");

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

      final chat = chatOf(id);
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

    /// A turn the user stopped before the model said anything, and the id of
    /// the empty reply it left on the end of the conversation. The `expect` is
    /// the fixture's own precondition: without it a test asserting the reply
    /// was kept would pass for the wrong reason.
    Future<(String, ChatController, String)> chatWithNothingSaid() async {
      app.backend.scriptedEvents = const [DoneEvent(aborted: true)];
      final (id, controller) = await chatWithOneTurn("hello");
      final empty = messagesOf(id).last;
      expect(empty.parts, isEmpty);
      app.backend.scriptedEvents = const [TextDelta("an answer"), DoneEvent()];
      return (id, controller, empty.id);
    }

    test("a turn that said nothing is replaced rather than kept beside", () async {
      final (id, controller, empty) = await chatWithNothingSaid();

      await controller.regenerate(empty);
      await waitIdle(id);

      expect(chatOf(id).messages.map(textOf), ["hello", "an answer"]);
      // No counter to press: the thread it replaced offered a blank page.
      expect(chatOf(id).branches, isEmpty);
      expect((await app.repo.openChat(id)).branches, isEmpty);
    });

    // The replacement joins the siblings and takes one of them away in the same
    // record, so the threads either side of the emptied one are untouched.
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

      final third = messagesOf(id).last.id;
      expect(textOf(messagesOf(id).last), "third answer");
      expect(chatOf(id).threadsAt(third), [first, second, third]);
      expect((await app.repo.openChat(id)).branches, chatOf(id).branches);
    });

    test("a turn that said nothing but was written under is kept", () async {
      final (id, controller, empty) = await chatWithNothingSaid();
      await controller.send("are you there?");
      await waitIdle(id);

      await controller.regenerate(empty);
      await waitIdle(id);

      // The reply stayed empty, but a conversation happened under it and that
      // is not something to delete for the sake of a counter.
      final chat = chatOf(id);
      expect(chat.threadsAt(chat.messages.last.id), [empty, chat.messages.last.id]);
    });

    test("regenerating an older thread joins them rather than nesting", () async {
      final (id, controller, first, second) = await twoReplies();
      await controller.stepThread(second, -1);

      app.backend.scriptedEvents = const [TextDelta("third answer"), DoneEvent()];
      await controller.regenerate(first);
      await waitIdle(id);

      final chat = chatOf(id);
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

    test("a finished or failed turn is closed with why it ended", () async {
      for (final (events, reason) in [
        (const <AgentEvent>[DoneEvent()], TurnEnd.done),
        (const <AgentEvent>[ErrorEvent("nope"), DoneEvent()], TurnEnd.error),
      ]) {
        app.backend.scriptedEvents = events;
        final (id, _) = await chatWithOneTurn("hello");
        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", reason));
      }
    });

    test("a turn the user stops is closed as aborted, not as an error", () async {
      app.backend.hold = Completer<void>();
      final (id, controller) = await startTurn("hello");
      await controller.abort();

      expect(records(id).last, isA<TurnEndRecord>()
          .having((r) => r.reason, "reason", TurnEnd.aborted));
      app.backend.hold!.complete();
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

      final chat = chatOf(id);
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
      Future<(String, ChatController)> killedChat(
          {List<MessagePart> reply = const [
            MessagePart.toolCall(
                toolCall:
                    ToolCall(id: "c1", name: "bash", argumentsJson: '{"command":"ls"}')),
          ]}) async {
        const id = "killed";
        await writeChatTo(
          store,
          Chat(
            state: ChatState(id: id, title: "t", createdAt: at, updatedAt: at),
            messages: [
              Message(id: "m1", role: MessageRole.user, createdAt: at, parts: const [
                MessagePart.text(text: "count the files"),
              ]),
              Message(id: "m2", role: MessageRole.assistant, createdAt: at, parts: reply),
            ],
          ),
          finished: false,
        );
        final controller = app.container.read(chatControllerProvider(id).notifier);
        await waitFor(() => app.container.read(chatControllerProvider(id)).chat != null,
            what: "the chat loading");
        return (id, controller);
      }

      test("a reply nothing closed is offered, and carrying it on closes it",
          () async {
        final (id, controller) = await killedChat();
        expect(chatOf(id).unfinished, isTrue);

        await controller.resume();
        await waitIdle(id);

        expect(app.backend.prompts, isEmpty);
        expect(app.backend.resumes.single.history.map((m) => m.id), ["m1", "m2"]);
        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", TurnEnd.done));
        expect(chatOf(id).unfinished, isFalse);
      });

      // A reply may open with `!` (a markdown image); it is still the reply
      // Continue carries on, not a command's.
      test("a reply whose text starts with a bang is carried on all the same",
          () async {
        final (id, controller) = await killedChat(
            reply: const [MessagePart.text(text: "![plot](plot.png)")]);
        await controller.resume();
        await waitIdle(id);

        expect(app.backend.resumes.single.history.map((m) => m.id), ["m1", "m2"]);
        expect(records(id).last,
            isA<TurnEndRecord>().having((r) => r.reason, "reason", TurnEnd.done));
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

    });
  });

  // A restore or a relaunch, which is nobody pressing stop — so what was
  // running comes back offered rather than recorded as ended. Shutting the
  // backend down first would abort them all.
  group("the app going away", () {
    /// A turn left open the way a real one is while the model is still working.
    /// Not the harness's `heldTurn`, which drives a `ChatPage`.
    Future<String> runningTurn() async {
      app.backend
        ..scriptedEvents = [const TextDelta("Half an ans")]
        ..hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      final (id, _) = await startTurn("hello");
      await waitFor(() => textOf(messagesOf(id).last).isNotEmpty,
          what: "the reply to start");
      // By hand: a scripted turn does not drive this, and it is what says which
      // chats are running — see `test/AGENTS.md`.
      app.backend.runningTurns.value = {id};
      return id;
    }

    test("interrupts the turns that are running", () async {
      final id = await runningTurn();

      await interruptLiveTurns(app.container);

      expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
      final stored = await app.store.load(id);
      expect((await app.store.readRecords(id)).whereType<TurnEndRecord>(), isEmpty);
      expect(stored.unfinished, isTrue);
      expect(stored.messages.last.plainText, "Half an ans");
    });

    // Reading the notifier for one would build a controller for a conversation
    // nobody is looking at; a reminder's turn closes its own log.
    test("builds no controller for a turn nothing is driving", () async {
      final chat = await app.repo.createChat();
      app.backend.runningTurns.value = {chat.state.id};

      await interruptLiveTurns(app.container);

      expect(app.container.exists(chatControllerProvider(chat.state.id)), isFalse);
    });
  });

  group("automatic retry rounds", () {
    /// A turn that fails retryably on every round: the send and every resume
    /// the controller makes get the same script, the last entry repeating.
    /// [turnRetries] is what the test seeds, since the setting decides how
    /// many rounds run at all.
    Future<(String, ChatController)> failingTurn(
        {int turnRetries = 0,
        bool retryable = true,
        String message = "connection lost"}) async {
      await app.seedSettings(AppSettings(turnRetries: turnRetries));
      app.backend.scriptedEvents = [
        ErrorEvent(message, retryable: retryable),
        DoneEvent(),
      ];
      final (id, controller) = await startTurn("hello");
      // A round per retry plus the send, each waiting out its own backoff.
      await waitIdle(id,
          limit: Duration(seconds: 2 + turnRetries * 4));
      return (id, controller);
    }

    test("carries a retryable failure on, showing the row between rounds",
        () async {
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [TextDelta("now it worked"), DoneEvent()],
      ];
      final (id, controller) = await startTurn("hello");
      await waitFor(() => viewOf(id).retry != null, what: "the retry row");
      expect(viewOf(id).retry, contains("Retrying (1/5)"));
      expect(viewOf(id).isRunning, isTrue);

      expect(await controller.turnDone, TurnEnd.done);
      expect(app.backend.resumes, hasLength(1));
      expect(textOf(messagesOf(id).last), "now it worked");
      expect(viewOf(id).isRunning, isFalse);
    });

    test("gives up after the setting's count and ends in error", () async {
      final (id, controller) = await failingTurn(turnRetries: 2);

      // The send plus the two rounds the setting allows.
      expect(app.backend.resumes, hasLength(2));
      expect(
          messagesOf(id).last.parts.whereType<ErrorPart>().single.message,
          contains("connection lost"));
      expect(controller.turnDone, isNull, reason: "already completed");
      expect(chatOf(id).unfinished, isTrue);
      // One error part across the rounds, on screen and in the log alike.
      final stored = await app.repo.openChat(id);
      expect(stored.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
    });

    test("neither off nor a failure nothing can carry on from retries",
        () async {
      for (final (retries, retryable) in [(0, true), (5, false)]) {
        app.backend.resumes.clear();
        final (id, _) =
            await failingTurn(turnRetries: retries, retryable: retryable);
        expect(app.backend.resumes, isEmpty);
        expect(messagesOf(id).last.parts.whereType<ErrorPart>().single.message,
            contains("connection lost"));
      }
    });

    test("stop during the backoff ends the turn without a resume", () async {
      await app.seedSettings(AppSettings(turnRetries: 3));
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [DoneEvent()],
      ];
      final (id, controller) = await startTurn("hello");
      await waitFor(
          () =>
              app.container.read(chatControllerProvider(id)).retry != null,
          what: "the retry row");

      await controller.interrupt();

      expect(app.backend.resumes, isEmpty);
      expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
    });

    test("notifies a failure only while the app is hidden", () async {
      await failingTurn(retryable: false, message: "provider down");
      expect(app.reminderAlarms.posted, isEmpty);

      app.appHidden = true;
      final (id, _) = await failingTurn(
          retryable: false, message: "provider down");

      final posted = app.reminderAlarms.posted.single;
      expect(posted.chatId, id);
      expect(posted.channel, "turns");
      expect(posted.title, "New chat");
      expect(posted.body, contains("provider down"));
    });

    test("does not notify a headless chat — the scheduler owns those",
        () async {
      app.appHidden = true;
      app.backend.scriptedEvents = const [
        ErrorEvent("provider down", retryable: false),
        DoneEvent(),
      ];
      final chat = await app.repo.createChat(meta: ChatMeta(headless: true));
      final controller =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await controller.send("hello");
      await waitIdle(chat.state.id);

      expect(app.reminderAlarms.posted, isEmpty);
    });
  });

  group("moving the chat to another project", () {
    // esbmc-verifier is byte-repair's alone, so the project's own library —
    // read from its real sources by the reload — is what decides whether a
    // mention of it resolves. `testLibrary` has none.
    Future<TestApp> appWithByteRepairLibrary() async {
      final app = TestApp.create();
      await app.container
          .read(promptLibraryProvider("byte-repair").notifier)
          .reload();
      return app;
    }

    /// The sidebar's move, driven at the container: invalidate, then wait for
    /// the reload. The predicate asks for the chat as well as the project —
    /// a building controller has neither, and null equals null.
    Future<void> moveAndReload(TestApp app, String chatId, String? project) async {
      await app.repo.moveChat(chatId, project);
      app.container.invalidate(chatControllerProvider(chatId));
      await waitFor(() async {
        final chat =
            app.container.read(chatControllerProvider(chatId)).chat;
        return chat != null && chat.state.project == project;
      }, what: "the reloaded chat");
    }

    test("the reloaded controller composes the next message against the new project",
        () async {
      final app = await appWithByteRepairLibrary();
      addTearDown(app.dispose);
      final chat = await app.repo.createChat(project: "byte-repair");
      final controller =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await controller.send("@esbmc-verifier verify src.c");
      await waitIdle(chat.state.id, target: app);
      // The byte-repair library resolved the mention before the move.
      expect(
        app.backend.prompts.single.prompt.documents.keys,
        contains("@esbmc-verifier"),
      );

      await moveAndReload(app, chat.state.id, null);
      // And the chat came back on the default project.
      expect(
        app.container
            .read(chatControllerProvider(chat.state.id))
            .chat!
            .state
            .project,
        isNull,
      );
      final reloaded =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await reloaded.send("@esbmc-verifier verify src.c");
      await waitIdle(chat.state.id, target: app);

      expect(app.backend.prompts.last.prompt.documents, isEmpty);
    });

    test("a chat whose controller was never built does not build one",
        () async {
      final chat = await app.repo.createChat(project: "work");
      await app.repo.moveChat(chat.state.id, null);

      expect(
        app.container.exists(chatControllerProvider(chat.state.id)),
        isFalse,
      );
    });
  });

  group("the room", () {
    test("a turn waiting on answers is waitingOnYou, and still running",
        () async {
      app.backend.scriptedEvents = const [
        QuestionRequestEvent(AskRequest(id: "q1", questions: [
          AskQuestion(question: "Which one?", options: [
            AskOption(label: "This one"),
          ]),
        ])),
      ];
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      final (id, _) = await startTurn("hello");
      await waitFor(
          () =>
              app.container.read(chatControllerProvider(id)).roomPhase ==
              RoomPhase.waitingOnYou,
          what: "the question");

      // The phase answers who may speak, not whether a turn is alive: the
      // spinner and the refusal to edit ride on isRunning, which is still set.
      final view = app.container.read(chatControllerProvider(id));
      expect(view.roomPhase, RoomPhase.waitingOnYou);
      expect(view.isRunning, isTrue);
      app.backend.hold!.complete();
      await waitIdle(id);
      expect(app.container.read(chatControllerProvider(id)).roomPhase,
          RoomPhase.open);
      // Let the teardown see a finished hold rather than completing twice.
      app.backend.hold = null;
    });

    test("a mention list schedules the members' turns in mention order",
        () async {
      await _inTeam(app);
      // Pinned sequential, the settle rule's test: under relay the second
      // prompt goes out while the first still runs.
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.sequential);
      app.backend.scriptedRounds = [
        for (var i = 0; i < 4; i++) ...[
          const [TextDelta("done"), DoneEvent()],
        ],
      ];
      final (id, _) = await startTurn(
          "hello @explore and @build, look at the tests",
          project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      final prompts = app.backend.prompts;
      // Both members run, in the order the message named them: the mention
      // list is the schedule. The first rides the opening turn; the second
      // is dispatched at the settle it causes.
      expect(prompts[0].settings.omadaMember, "explore");
      expect(prompts[1].settings.omadaMember, "build");
      // The second member answers the same prompt — the message was
      // addressed to them both.
      expect(prompts[1].prompt.id, prompts[0].prompt.id);
    });

    test("a direct chat never stamps, whatever the prompt names", () async {
      // Omada off: the reply is the main agent's, using the named agent's
      // instructions. No stamp, no label - the label would claim a member
      // authored the house's voice.
      final (id, _) =
          await chatWithOneTurn("hello @explore, find the tests");

      expect(messagesOf(id).first.documents, contains("@explore"));
      expect(messagesOf(id).last.author, isNull);
      expect(app.backend.prompts.single.prompt.addressees, isEmpty);
    });

    test("a command is not addressed to anyone it names, resent or not",
        () async {
      final (id, controller) = await chatWithOneTurn("!grep @explore src/");
      expect(messagesOf(id).last.author, isNull);

      await controller.regenerate(messagesOf(id).last.id);
      await waitIdle(id);

      expect(messagesOf(id).last.author, isNull);
    });

    test("an edit, and a regenerate of it, carry the prompt's author",
        () async {
      await _inTeam(app);
      final (id, controller) = await chatWithOneTurn("helo", project: "team");

      await controller.editAndResend(messagesOf(id).first.id, "hello @explore");
      await waitIdle(id);
      expect(messagesOf(id).last.author, "@explore");

      await controller.regenerate(messagesOf(id).first.id);
      await waitIdle(id);
      expect(messagesOf(id).last.author, "@explore");
    });

    test("a reply naming another member hands the next turn to them", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        // Build's reply hands off to explore.
        const [TextDelta("let me get @explore to confirm"), DoneEvent()],
        const [TextDelta("found them"), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @build, look at the tests", project: "team");

      await waitFor(() => app.backend.prompts.length >= 2, what: "the handoff");
      await waitIdle(id);

      final messages = messagesOf(id);
      // The handoff's prompt is the mentioning reply itself, said again as
      // what the next member is answering.
      expect(app.backend.prompts[1].prompt.id, messages[1].id);
      // And the settings carried the member to the backend.
      expect(app.backend.prompts[1].settings.omadaMember, "explore");
      // The round's second reply is authored by the member it was addressed
      // to — the record's `author` is what the label reads.
      expect(messages.last.author, "@explore");
    });

    test("a reply naming its own author hands off to nobody", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        const [TextDelta("hello @explore and @build"), DoneEvent()],
        const [TextDelta("hi"), DoneEvent()],
        const [TextDelta("never asked"), DoneEvent()],
      ];
      final (id, _) = await startTurn("@explore greet the room", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect([for (final p in app.backend.prompts) p.settings.omadaMember],
          ["explore", "build"]);
      expect(messagesOf(id)[1].addressees, ["@build"]);
    });

    test("a reply's routing is stamped on its close and survives a reload",
        () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        const [TextDelta("over to @explore"), DoneEvent()],
        const [TextDelta("done"), DoneEvent()],
      ];
      final (id, _) = await startTurn("@build look", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect(messagesOf(id)[1].addressees, ["@explore"]);
      expect(messagesOf(id)[2].addressees, isEmpty);
      final reloaded = await app.repo.openChat(id);
      expect(reloaded.messages[1].addressees, ["@explore"]);
    });

    test("a member named by several replies runs once", () async {
      app.dispose();
      app = TestApp.create(
          library: PromptLibrary([
        for (final name in ["explore", "build", "general"])
          PromptDocument.parse(CompletionKind.agent, name,
              "---\ndescription: $name\n---\n\nDo $name.\n"),
      ]));
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.parallel);
      app.backend.scriptedRounds = [
        const [TextDelta("ask @general"), DoneEvent()],
        const [TextDelta("ask @general too"), DoneEvent()],
        const [TextDelta("answered both"), DoneEvent()],
        const [TextDelta("never asked"), DoneEvent()],
      ];
      final (id, _) =
          await startTurn("@explore and @build, look", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      final members = [
        for (final p in app.backend.prompts) p.settings.omadaMember
      ];
      expect(members.where((m) => m == "general"), hasLength(1));
      // The one turn answers the newest reply, the older one in its history.
      final messages = messagesOf(id);
      final fromExplore = messages.firstWhere((m) => m.author == "@explore");
      final fromBuild = messages.firstWhere((m) => m.author == "@build");
      final general = app.backend.prompts.last;
      expect(general.prompt.id, fromBuild.id);
      expect(general.history.map((m) => m.id), contains(fromExplore.id));
    });

    test("the chain stops at the cap and the user resets it", () async {
      await _inTeam(app);
      // A cap of its own: the app default is ten, and three rounds is the
      // shape this test pins.
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaMaxGenerations(3);
      // Each reply hands to the other member: its own handle is not an
      // address.
      app.backend.scriptedRounds = [
        for (var i = 0; i < 10; i++) ...[
          const [TextDelta("see @explore and @build"), DoneEvent()],
        ],
      ];
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // Three agent turns — the addressee and two handoffs — and the round
      // stops: the fifth scripted round is never asked for.
      expect(app.backend.prompts, hasLength(3));
      // The user speaking resets the round, so a new mention starts fresh.
      await controller.send("again @explore");
      await waitIdle(id, limit: const Duration(seconds: 5));
      expect(app.backend.prompts.length, greaterThan(4));
    });

    test("each flip of the room's mode opens a section, and nothing else does",
        () async {
      await _inTeam(app);
      final team = app.container.read(projectSettingsProvider("team").notifier);
      final (id, controller) = await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));
      await controller.send("plain follow-up");
      await waitIdle(id, limit: const Duration(seconds: 5));
      List<bool> sections(Chat chat) =>
          [for (final s in entriesOf(chat).whereType<SectionEntry>()) s.omada];
      // A repeat stamp of the same mode is not a flip.
      expect(sections(await app.repo.openChat(id)), [true]);

      await team.setOmada(false);
      await controller.send("plain message");
      await waitIdle(id, limit: const Duration(seconds: 5));
      await team.setOmada(true);
      await controller.send("another message");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // Only the openers carry the mode, and the off one bounds the section.
      expect(messagesOf(id).map((m) => m.omadaOn).nonNulls,
          [true, true, false, true]);
      expect(sections(await app.repo.openChat(id)), [true, false, true]);
    });

    test("a silent reply is on the log, not the page, and hands to no one",
        () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [_silent];
      final (id, _) =
          await startTurn("hello @explore, want this?", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      final reply = messagesOf(id).last;
      expect(endedSilently(reply), isTrue);
      expect(reply.addressees, isEmpty);
      expect(app.backend.prompts, hasLength(1));
      // The reason is kept for the record.
      final reloaded = await app.repo.openChat(id);
      expect(
          reloaded.messages.last.parts
              .whereType<ToolCallPart>()
              .single
              .toolCall
              .argumentsJson,
          contains("Not for me."));
      expect(entriesOf(chatOf(id)).whereType<MessageEntry>(), hasLength(1));
    });

    test("a silent reply does not cancel what the user scheduled", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        _silent,
        const [TextDelta("on it"), DoneEvent()],
      ];
      final (id, _) = await startTurn(
          "@explore and @build, have a look", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect(app.backend.prompts, hasLength(2));
      expect(app.backend.prompts[1].settings.omadaMember, "build");
    });

    for (final ordering in [OmadaOrdering.parallel, OmadaOrdering.relay, null]) {
      test("${ordering?.name ?? "the default"} ordering fans a mention list out at once",
          () async {
        await _inTeam(app);
        if (ordering != null) {
          await app.container
              .read(projectSettingsProvider("team").notifier)
              .setOmadaOrdering(ordering);
        }
        // Both turns hold until this completes: a fan-out is two turns in
        // flight, not one after another.
        app.backend.hold = Completer<void>();
        addTearDown(() => app.backend.hold?.complete());
        final (id, _) = await startTurn(
            "@explore and @build, have a look", project: "team");

        await waitFor(() => app.backend.prompts.length >= 2,
            what: "the fan-out", limit: const Duration(seconds: 5));
        expect(app.backend.hold?.isCompleted, isFalse);
        expect([for (final p in app.backend.prompts) p.settings.omadaMember],
            ["explore", "build"]);

        app.backend.hold?.complete();
        app.backend.hold = null;
        await waitIdle(id, limit: const Duration(seconds: 5));
      });
    }

    test("a handoff under parallel ordering waits for the siblings", () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.parallel);
      app.backend.scriptedRounds = [
        // The fan-out: explore hands to build, build hands to nobody.
        const [TextDelta("over to @build"), DoneEvent()],
        const [TextDelta("done here"), DoneEvent()],
        // The settle-first wave: build's handoff runs only once both
        // siblings of the first wave are finished.
        const [TextDelta("build speaking"), DoneEvent()],
      ];
      final (id, _) = await startTurn(
          "@explore and @build, split this up", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The first wave was two turns; the handoff from explore's reply is
      // the third prompt, dispatched at the settle the wave caused.
      expect(app.backend.prompts, hasLength(3));
      expect(app.backend.prompts[2].settings.omadaMember, "build");
    });

    test("relay hands off while a sibling still holds the floor", () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.relay);
      // Explore's turn holds the floor while it streams; its reply names
      // build. Under crossfire this handoff would wait for explore's settle
      // — which is the hold — under relay it runs beside it.
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      app.backend.scriptedRounds = [
        const [TextDelta("over to @build"), DoneEvent()],
      ];
      final (id, _) =
          await startTurn("hello @explore, look at the tests", project: "team");
      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the handoff", limit: const Duration(seconds: 5));

      // Two prompts while the hold is still up: the handoff ran while the
      // first turn's stream is held open beside it.
      expect(app.backend.hold?.isCompleted, isFalse);
      expect(app.backend.prompts[1].settings.omadaMember, "build");
      // The handoff's prompt is explore's mentioning reply, said again as
      // what the next member is answering.
      expect(app.backend.prompts[1].prompt.id, messagesOf(id)[1].id);

      app.backend.hold?.complete();
      app.backend.hold = null;
      app.backend.scriptedRounds = [const [TextDelta("on it"), DoneEvent()]];
      await waitIdle(id, limit: const Duration(seconds: 5));
      expect(app.backend.prompts, hasLength(2));
    });

    test("relay answers a say for an idle member at once", () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.relay);
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      app.backend.scriptedRounds = [const [TextDelta("on it")]];
      final (id, controller) =
          await startTurn("hello @explore, take your time", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      // Said for a member with no turn in flight: relay starts it at once,
      // mid-sibling-turn.
      await controller.send("and @build after this");
      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final said =
          chat.messages.where((m) => textOf(m) == "and @build after this").single;
      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the say for the idle member", limit: const Duration(seconds: 5));
      expect(app.backend.hold?.isCompleted, isFalse);
      expect(app.backend.prompts[1].settings.omadaMember, "build");
      // The turn ran on the message the log already holds, not a second
      // composition of the same words.
      expect(app.backend.prompts[1].prompt.id, said.id);

      app.backend.hold?.complete();
      app.backend.hold = null;
      app.backend.scriptedRounds = [
        const [TextDelta("done"), DoneEvent()],
        const [TextDelta("done too"), DoneEvent()],
      ];
      await waitIdle(id, limit: const Duration(seconds: 5));
      expect(messagesOf(id).where((m) => textOf(m) == "and @build after this"),
          hasLength(1));
    });

    test("relay respects the cap with two waves in flight", () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.relay);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaMaxGenerations(2);
      // Explore hands to build, build's turn completes and hands again —
      // the second handoff is generation 2, past the cap, and is dropped at
      // dispatch while the queued user prompt behind it is kept.
      app.backend.scriptedRounds = [
        const [TextDelta("over to @build"), DoneEvent()],
        const [TextDelta("see @explore"), DoneEvent()],
      ];
      final (id, _) =
          await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The addressee and one handoff; explore's second mention would be
      // generation 2 and the cap stopped it.
      expect(app.backend.prompts, hasLength(2));
      expect(app.backend.prompts[1].settings.omadaMember, "build");
    });

    test("a relay round ended in error clears the lanes", () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.relay);
      // Explore's turn fails; whatever the round had scheduled after it —
      // the say queued for explore's own lane — is a round the user stopped
      // by that failure. The say lands on the log while explore speaks (the
      // error streams first, and the stream stays open on the hold, since a
      // scripted round without a DoneEvent never closes), and the failure
      // drops it.
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      app.backend.scriptedRounds = [
        [ErrorEvent("provider down", retryable: false)],
      ];
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");
      await controller.send("again @explore, one more thing");

      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect(app.backend.prompts, hasLength(1));
      // And a fresh mention runs again: the round is over, not stuck.
      app.backend.scriptedRounds = [const [TextDelta("on it"), DoneEvent()]];
      await controller.send("hello @build, you are next");
      await waitIdle(id, limit: const Duration(seconds: 5));
      expect(app.backend.prompts.last.settings.omadaMember, "build");
    });

    test("a retried turn resumes its own reply while a sibling streams",
        () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.relay);
      await app.container.read(appSettingsProvider.notifier).setTurnRetries(1);
      // Explore's turn fails; its round re-enters resume and streams the
      // recovery. Build's say opens a turn beside it — its reply is the
      // last assistant message by the time the recovery lands — and the
      // round must still have appended to explore's reply, not build's.
      // One scripted round per turn, in the order they are opened: the
      // failure, build's turn, the recovery.
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [TextDelta("on it"), DoneEvent()],
        [TextDelta("recovered"), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitFor(
          () => app.container.read(chatControllerProvider(id)).retry != null,
          what: "the retry row");

      // Build's turn opens while explore's round waits out its backoff.
      await controller.send("and @build now");
      await waitFor(() => app.backend.resumes.isNotEmpty,
          what: "the retry round", limit: const Duration(seconds: 10));
      await waitIdle(id, limit: const Duration(seconds: 10));

      // The recovery is on explore's reply — the one the round owns — and
      // build's reply is untouched by it.
      final messages = messagesOf(id);
      expect(textOf(messages[1]), "recovered");
      expect(textOf(messages[3]), "on it");
      expect(app.backend.resumes, hasLength(1));
      expect(app.backend.resumes.single.settings.omadaMember, "explore");
    });

    test("a say for a member already speaking queues for their next turn",
        () async {
      await _inTeam(app);
      // The member's turn holds the floor: its scripted round carries no
      // DoneEvent and the hold keeps the stream open, so the room is busy
      // the whole time.
      app.backend.hold = Completer<void>();
      app.backend.scriptedRounds = [
        const [TextDelta("working on it")],
        const [TextDelta("again, done"), DoneEvent()],
      ];
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) =
          await startTurn("hello @explore, take your time", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      // Said to the member who is already speaking, held for after. It lands
      // on the log, and it waits: the room schedules it, the settle
      // dispatches it.
      await controller.send("again @explore, one more thing", queue: true);
      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final said = chat.messages
          .where((m) => textOf(m) == "again @explore, one more thing")
          .single;

      // No second turn opens while the first still has the floor.
      final end = DateTime.now().add(const Duration(milliseconds: 500));
      while (DateTime.now().isBefore(end)) {
        expect(app.backend.prompts, hasLength(1),
            reason:
                "a say for a busy member must queue, not spawn a parallel turn");
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // The settle runs it: the same member's turn, on the message the log
      // already holds.
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect(app.backend.prompts, hasLength(2));
      expect(app.backend.prompts[1].settings.omadaMember, "explore");
      expect(app.backend.prompts[1].prompt.id, said.id);
      expect(
          messagesOf(id)
              .where((m) => textOf(m) == "again @explore, one more thing"),
          hasLength(1));
    });

    test("a say in a direct chat queues for the room's settle too", () async {
      // Omada off: the say addresses nobody, and the bug was not about
      // members — the drain dispatched whatever landed, so even here a say
      // opened a second turn beside the first instead of queueing.
      app.backend.hold = Completer<void>();
      app.backend.scriptedRounds = [
        const [TextDelta("thinking")],
        const [TextDelta("later, done"), DoneEvent()],
      ];
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) = await startTurn("hello, take your time");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      await controller.send("one more thing", queue: true);

      // No second turn opens while the first still has the floor.
      final end = DateTime.now().add(const Duration(milliseconds: 500));
      while (DateTime.now().isBefore(end)) {
        expect(app.backend.prompts, hasLength(1),
            reason: "a say to a busy room must queue, not spawn a turn");
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // The settle runs it: the main agent's turn, on the message the log
      // already holds.
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the queued say", limit: const Duration(seconds: 5));
      await waitIdle(id, limit: const Duration(seconds: 5));

      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final said =
          chat.messages.where((m) => textOf(m) == "one more thing").single;
      expect(app.backend.prompts, hasLength(2));
      expect(app.backend.prompts[1].settings.omadaMember, isNull);
      expect(app.backend.prompts[1].prompt.id, said.id);
      expect(messagesOf(id).where((m) => textOf(m) == "one more thing"),
          hasLength(1));
    });

    test("a say over a running turn steers it, landing in its reply",
        () async {
      app.backend.hold = Completer<void>();
      app.backend.scriptedEvents = const [TextDelta("looking")];
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) = await startTurn("hello, take your time");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      await controller.send("use the other file");

      // Waiting for the turn's next step: not on the log, and no turn of
      // its own.
      var view = app.container.read(chatControllerProvider(id));
      expect(view.steering.map(textOf), ["use the other file"]);
      expect(view.chat!.messages.where((m) => textOf(m) == "use the other file"),
          isEmpty);

      app.backend.deliverSteers();
      await waitFor(
          () => app.container.read(chatControllerProvider(id)).steering.isEmpty,
          what: "the steer read");
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitIdle(id, limit: const Duration(seconds: 5));

      expect(app.backend.prompts, hasLength(1));
      view = app.container.read(chatControllerProvider(id));
      final reply = view.chat!.messages.last;
      expect(reply.role, MessageRole.assistant);
      expect(reply.parts.whereType<SteerPart>().map((p) => textOf(p.message)),
          ["use the other file"]);
      // A reload reads the same reply.
      final logged = messagesOf(id).last;
      expect(logged.parts.whereType<SteerPart>(), hasLength(1));
    });

    test("a steer the turn never read is said after it", () async {
      app.backend.hold = Completer<void>();
      app.backend.scriptedRounds = [
        const [TextDelta("thinking")],
        const [TextDelta("later, done"), DoneEvent()],
      ];
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) = await startTurn("hello, take your time");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      await controller.send("one more thing");
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the unread steer", limit: const Duration(seconds: 5));
      await waitIdle(id, limit: const Duration(seconds: 5));

      final said = messagesOf(id).where((m) => textOf(m) == "one more thing");
      expect(said, hasLength(1));
      expect(said.single.role, MessageRole.user);
      expect(app.backend.prompts[1].prompt.id, said.single.id);
      expect(app.container.read(chatControllerProvider(id)).steering, isEmpty);
    });

    test("a waiting steer can be sent after the turn, or taken back",
        () async {
      app.backend.hold = Completer<void>();
      app.backend.scriptedRounds = [
        const [TextDelta("thinking")],
        const [TextDelta("later, done"), DoneEvent()],
      ];
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) = await startTurn("hello, take your time");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");
      // What the composer asks before offering the choice: a command waits.
      expect(controller.steers("keep this for later"), isTrue);
      expect(controller.steers("!ls"), isFalse);
      expect(controller.steers("/compact"), isFalse);

      await controller.send("keep this for later");
      final picture = Attachment(
          filename: "shot.png",
          mimeType: "image/png",
          bytes: Uint8List.fromList([1, 2, 3]));
      await controller.send("never mind", attachments: [picture]);
      final steering = app.container.read(chatControllerProvider(id)).steering;
      await controller.queueSteer(steering.first.id);
      // Back as the composer held it, the file read back off the chat.
      final back = await controller.withdrawSteer(steering.last.id);
      expect(back?.text, "never mind");
      expect(back?.attachments.single.filename, "shot.png");
      expect(back?.attachments.single.bytes, [1, 2, 3]);
      // Gone from the chat: nothing names it, and a resend saves its own.
      expect(
          await app.store
              .readResource(id, steering.last.files.single.resource),
          isNull);

      // Neither is the turn's to read any more; the queued one is on the log.
      expect(app.container.read(chatControllerProvider(id)).steering, isEmpty);
      expect(app.backend.steers!.take(), isEmpty);
      expect(
          app.container
              .read(chatControllerProvider(id))
              .chat!
              .messages
              .map(textOf),
          contains("keep this for later"));

      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the queued say", limit: const Duration(seconds: 5));
      await waitIdle(id, limit: const Duration(seconds: 5));
      expect(app.backend.prompts, hasLength(2));
      expect(messagesOf(id).map(textOf), isNot(contains("never mind")));
    });

    test("a handoff survives a settle the schedule holds something", () async {
      // The shape the `_endTurn` guard removal exists for: the settle that
      // ends this turn reads a schedule it cannot finish — sequential order
      // runs the head member's item and leaves the next member's queued —
      // and a schedule non-empty at the settle must not stop the reply's
      // handoff from being parked for the wave's settle. The guard it
      // replaced returned before the settle and dropped the handoff.
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.sequential);
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      app.backend.scriptedRounds = [
        // Explore holds the floor, then hands to build.
        const [TextDelta("over to @build")],
        // The two queued says run in schedule order, then the handoff.
        const [TextDelta("got it, done"), DoneEvent()],
        const [TextDelta("looking, done"), DoneEvent()],
        const [TextDelta("on it, done"), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @explore, take your time", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      // Two says while explore still speaks: one for build, one for the
      // house. Sequential order dispatches only the first of them at the
      // settle, so the schedule is not empty when the settle runs — and the
      // reply's handoff must still be parked, not skipped.
      await controller.send("and @build after this");
      await controller.send("and also take a look");
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitFor(() => app.backend.prompts.length >= 4,
          what: "the parked handoff", limit: const Duration(seconds: 5));
      await waitIdle(id, limit: const Duration(seconds: 5));

      final messages = messagesOf(id);
      // The say for build ran as build's turn on the message the log
      // already holds; the say for the house ran as the main agent's.
      expect(app.backend.prompts[1].settings.omadaMember, "build");
      expect(app.backend.prompts[1].prompt.id, messages[2].id);
      expect(app.backend.prompts[2].settings.omadaMember, isNull);
      expect(app.backend.prompts[2].prompt.id, messages[3].id);
      // And the handoff followed: explore's mentioning reply, build's turn.
      expect(app.backend.prompts[3].settings.omadaMember, "build");
      expect(app.backend.prompts[3].prompt.id, messages[1].id);
    });

    test("a message naming no known member is answered by the house",
        () async {
      await _inTeam(app);
      for (final text in ["plain hello", "hello @nobody-knows-me"]) {
        final (id, _) = await chatWithOneTurn(text, project: "team");
        final sent = app.backend.prompts.last;
        expect(sent.settings.omadaMember, isNull);
        expect(sent.prompt.addressees, isEmpty);
        expect(messagesOf(id).last.author, isNull);
      }
    });

    test("the say the room routed to one member records who it addressed",
        () async {
      await _inTeam(app);
      final (id, _) =
          await chatWithOneTurn("hello @explore", project: "team");

      // The routing record rides the say: the room's own answer to who a say
      // was for, worded for every other participant by the projection — the
      // record on screen reads the same as the copy the backend worded.
      final say = messagesOf(id).first;
      expect(say.documents, contains("@explore"));
      expect(say.addressees, ["@explore"]);
      expect(app.backend.prompts.single.prompt.addressees, ["@explore"]);
      // And the author stamp rides the reply, as the sync's covered ids
      // expect.
      expect(messagesOf(id).last.author, "@explore");
    });

    test("a queued say records who it is for, at say time", () async {
      await _inTeam(app);
      app.backend.hold = Completer<void>();
      app.backend.scriptedRounds = [
        const [TextDelta("hello from explore")],
        const [TextDelta("on it"), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");
      await controller.send("now look at the tests, @build");
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The stamp rode the say when it landed, and every later reader — the
      // build turn the room dispatched among its replies — words it from the
      // log's record.
      final buildSay = messagesOf(id)[2];
      expect(buildSay.addressees, ["@build"]);
      expect(app.backend.prompts.last.prompt.addressees, ["@build"]);
      expect(app.backend.prompts.last.settings.omadaMember, "build");
    });

    /// A trigger fire through the real driver, into a chat that already had a
    /// turn. The ref a driver needs comes from the provider it is read through.
    Future<String> fire(String? project, String text) async {
      final (id, _) = await chatWithOneTurn("kick things off", project: project);
      final driver = app.container.read(
          Provider<ChatControllerTriggerTurnDriver>(
              (ref) => ChatControllerTriggerTurnDriver(ref)));
      await driver.send(id, text);
      await waitIdle(id, limit: const Duration(seconds: 5));
      return id;
    }

    test("a trigger fire naming a member is a say the room routes to them",
        () async {
      await _inTeam(app);
      const text = "@explore\n\ncheck the builds\n\n(schedule: 9:00)";
      final id = await fire("team", text);

      expect(app.backend.prompts.last.settings.omadaMember, "explore");
      expect(app.backend.prompts.last.prompt.plainText, text);
      expect(messagesOf(id).last.author, "@explore");
    });

    test("a trigger fire naming no member reaches the house", () async {
      await _inTeam(app);
      final id = await fire("team", "check the builds\n\n(schedule: 9:00)");

      expect(app.backend.prompts.last.settings.omadaMember, isNull);
      expect(messagesOf(id).last.author, isNull);
    });

    // Omada off: no promotion, no stamp — the mention rides inline.
    test("a direct chat takes a member's fire as instruction material",
        () async {
      final id = await fire(null, "@explore\n\ncheck the builds");

      expect(app.backend.prompts.last.settings.omadaMember, isNull);
      expect(messagesOf(id).last.author, isNull);
      expect(app.backend.prompts.last.prompt.plainText, contains("@explore"));
    });

  });
group("a banner answer through the controller", () {
    // The controller invalidates the project tiers after an answer, so the
    // settings pages reflect what the prompt granted without a restart — the
    // stale UI the live tests tripped over. The answer also reaches the
    // turn's settings, which is what the backend drives the agent with.
    test("always in project lands the rule where the settings read", () async {
      const approval = ToolApproval(
        id: "call-1",
        toolName: "bash",
        argumentsText: "git status",
        argumentsJson: '{"command": "git status"}',
      );
      app.backend.scriptedEvents = [ApprovalRequestEvent(approval)];
      app.backend.hold = Completer<void>();
      final (id, controller) = await startTurn("run git status");
      // The banner event is yielded as the stream parks on the hold; wait for
      // the banner itself rather than a beat of the loop.
      await waitFor(
          () => app.container
              .read(chatControllerProvider(id))
              .approvals
              .values
              .expand((a) => a)
              .isNotEmpty,
          what: "the approval banner");
      final banner = app.container.read(chatControllerProvider(id)).approvals
          .values
          .expand((a) => a)
          .first;
      expect(banner.toolName, "bash");

      await controller.respondApproval(
          banner.id, ApprovalResponse.alwaysAllowProject,
          approval: banner);
      if (app.backend.hold?.isCompleted == false) {
        app.backend.hold?.complete();
      }
      await waitIdle(id);

      // The tier the answer named, read from disk the way a restart would.
      final settings = ProjectSettings.load(app.config, project: null);
      expect(settings.permissions.map((r) => r.pattern),
          contains("git status *"));
      // The provider was invalidated: the container's read is the fresh one.
      expect(
          app.container.read(projectSettingsProvider(null)).permissions.map(
              (r) => r.pattern),
          contains("git status *"));
    });

    test("the three tiers compose into the turn's settings", () async {
      final (id, controller) = await startTurn("go");
      await waitIdle(id);

      await controller.respondApproval("none", ApprovalResponse.deny);
      // Seed the tiers after the turn so the next send resolves fresh.
      await app.repo.saveMeta(id, ChatMeta(permissions: [
        const PermissionRule(
            tool: "bash",
            pattern: "chat rule *",
            decision: PermissionDecision.allow),
      ]));
      final project = ProjectSettings()
        ..permissions = [
          const PermissionRule(
              tool: "bash",
              pattern: "project rule *",
              decision: PermissionDecision.deny),
        ];
      await project.save(app.config, project: null);
      app.container.invalidate(projectSettingsProvider(null));

      // waitIdle completed the first turn; the second send resolves the tiers.
      final controller2 = app.container.read(chatControllerProvider(id).notifier);
      await controller2.send("again");
      await waitIdle(id);

      final resolved = (await app.backend.prompts.last.settings.policy())
          .permissions
          .map((r) => r.pattern)
          .toList();
      expect(resolved, containsAll(["chat rule *", "project rule *"]));
      // Order is the evaluation order: chat first.
      expect(resolved.indexOf("chat rule *"),
          lessThan(resolved.indexOf("project rule *")));
    });
  });

  group("compact", () {
    /// A chat with the bundled-shaped wired skill in its library, so `/compact`
    /// resolves. The test library has none, so the write-and-reload is what a
    /// real app's bundled preset is.
    Future<(String, ChatController)> chatWithCompactSkill() async {
      await writeSkill(app, "compact",
          metadata: {"invocation": "callback"});
      await app.container.read(promptLibraryProvider(null).notifier).reload();
      final chat = await app.repo.createChat();
      final controller =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await controller.send("hello");
      await waitIdle(chat.state.id);
      return (chat.state.id, controller);
    }

    test("dispatches to the callback, not to a model", () async {
      final (id, controller) = await chatWithCompactSkill();
      app.backend.scriptedSummary = "The user said hello.";
      await controller.send("/compact keep the greeting");
      await waitIdle(id);

      // The prompt never reached the backend's turn stream: no model was
      // asked, and the compact callback was asked instead, with the argument.
      // The one prompt in the table is the "hello" the chat was set up with.
      expect(app.backend.prompts, hasLength(1));
      expect(app.backend.prompts.single.prompt.plainText, "hello");
      expect(app.backend.compactionCalls.single.instructions,
          "keep the greeting");
      // The marker is on the log and the chat the page reads.
      final chat = await app.repo.openChat(id);
      expect(chat.compactions.single.summary, "The user said hello.");
      expect(chat.compactions.single.upToMessageId,
          messagesOf(id).last.id);
      // The marker rebuilds the session: one reset with it applied.
      expect(app.backend.resets, hasLength(1));
      // A callback turn is not a thing said: the title namer is not asked,
      // and the turn closed done, so there is no ResumeBar to answer.
      expect(app.backend.questions, isEmpty);
      expect(chat.unfinished, isFalse);
      // The marker is a divider after the boundary message it covers.
      final entries = entriesOf(chat);
      expect(entries.last,
          isA<CompactionEntry>().having((c) => c.summary, "summary", "The user said hello."));
    });

    test("a failed summarizer leaves the conversation untouched", () async {
      final (id, controller) = await chatWithCompactSkill();
      // scriptedSummary null: nothing answered.
      await controller.send("/compact");
      await waitIdle(id);

      expect(app.backend.compactionCalls, hasLength(1));
      expect(await app.repo.openChat(id), chatOf(id));
    });

    test("is refused while a turn runs, and never queued", () async {
      final (id, controller) = await chatWithCompactSkill();
      app.backend.scriptedSummary = "The user said hello.";
      app.backend.hold = Completer<void>();
      await controller.send("hold the room");
      await waitFor(
          () => app.container.read(chatControllerProvider(id)).isRunning,
          what: "the turn");
      await controller.send("/compact");

      expect(app.backend.compactionCalls, isEmpty);
      // Not queued either: nothing arrives once the room settles.
      app.backend.hold!.complete();
      await waitIdle(id);
      expect(app.backend.compactionCalls, isEmpty);
    });

    test("an unknown wired name degrades to an ordinary message", () async {
      await writeSkill(app, "notbuilt",
          metadata: {"invocation": "callback"});
      await app.container.read(promptLibraryProvider(null).notifier).reload();
      final (id, _) = await chatWithOneTurn("/notbuilt do things");

      // No callback under that name: the text went to the model as it was.
      expect(app.backend.prompts.single.prompt.plainText,
          "/notbuilt do things");
      expect(app.backend.compactionCalls, isEmpty);
      expect(messagesOf(id).last.parts.whereType<ToolResultPart>(), isEmpty);
    });

    test("a turn that pushed the context past the share compacts on its own",
        () async {
      final (id, controller) = await chatWithCompactSkill();
      // Well under any share of the 128k window the fake reports.
      app.backend.usageHolder[id] = 60000;
      await controller.send("grow a little");
      await waitIdle(id);
      expect(app.backend.compactionCalls, isEmpty);

      // Past it now: the next settled turn compacts, with no instructions.
      await app.container
          .read(appSettingsProvider.notifier)
          .setAutoCompactPercent(60);
      app.backend.usageHolder[id] = 120000;
      app.backend.scriptedSummary = "Everything so far.";
      await controller.send("grow a lot");
      await waitIdle(id);
      expect(app.backend.compactionCalls, hasLength(1));
      final chat = await app.repo.openChat(id);
      expect(chat.compactions.single.summary, "Everything so far.");
    });

    test("does not run twice without a turn between, or when off", () async {
      final (id, controller) = await chatWithCompactSkill();
      // Off: nothing compacts however deep the context.
      await app.container
          .read(appSettingsProvider.notifier)
          .setAutoCompact(false);
      app.backend.usageHolder[id] = 999999;
      app.backend.scriptedSummary = "Everything so far.";
      await controller.send("one");
      await waitIdle(id);
      expect(app.backend.compactionCalls, isEmpty);

      await app.container.read(appSettingsProvider.notifier).setAutoCompact(true);
      await controller.send("two");
      await waitIdle(id);
      expect(app.backend.compactionCalls, hasLength(1));
      // The marker fronts the projection, so the next request weighs the
      // summary and the fresh exchange, under the share again — what a real
      // provider reports, which the fake models here. Holding usage over the
      // share would ask for a second compaction, and rightly.
      app.backend.usageHolder[id] = 30000;
      await controller.send("three");
      await waitIdle(id);
      expect(app.backend.compactionCalls, hasLength(1));
    });

  });

}

/// Settings with chat naming turned on. A getter, not a constant: settings are
/// mutable and each test writes its own copy.
AppSettings get _withTitleModel =>
    AppSettings(titleProviderId: "anthropic", titleModelId: "claude-haiku-3");

/// A project with Omada on, its library the test one — the harness seeds the
/// test library for every project, so the chat's project is all a test needs.
Future<void> _inTeam(TestApp app) async {
  await app.repo.createProject("team");
  await app.container
      .read(projectSettingsProvider("team").notifier)
      .setOmada(true);
}

/// A member's turn that ends with `end_turn` and says nothing.
const _silent = <AgentEvent>[
  ToolCallEvent(ToolCall(
      id: "end",
      name: endTurnToolName,
      argumentsJson: '{"reason":"Not for me."}')),
  ToolResultEvent(ToolResult(callId: "end", returnCode: 0, output: "Turn ended.")),
  DoneEvent(),
];
