import "dart:io";

import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/templates.dart" show passWord;
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/project_settings.dart"
    show OmadaOrdering;
import "package:agent_chat/providers.dart"
    show projectSettingsProvider, promptLibraryProvider;
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart" show entriesOf, SectionEntry;

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

  Chat chatOf(String id) => app.container.read(chatControllerProvider(id)).chat!;

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
    // Every message is answered by the main agent, and its phase is open once
    // the turn is over — the room's two facts, pinned at one of the seams.
    expect(app.container.read(chatControllerProvider(id)).roomPhase,
        RoomPhase.open);
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

  test("what the turn is doing is held while it runs", () async {
    app.backend.scriptedEvents = const [
      StatusEvent("Thinking"),
      StatusEvent("Reading the prompt · 43%"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The latest replaces the last rather than accumulating: it is one row, and
    // the most recent thing said is the true one.
    expect(app.container.read(chatControllerProvider(id)).status,
        "Reading the prompt · 43%");
    app.backend.hold!.complete();
  });

  test("the reply starting is what takes the status away", () async {
    app.backend.scriptedEvents = const [
      StatusEvent("Thinking"),
      StatusEvent(null),
      TextDelta("here you go"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // From here the caret says the turn is alive, and a label beside it would
    // be the second thing saying so.
    expect(app.container.read(chatControllerProvider(id)).status, isNull);
    app.backend.hold!.complete();
  });

  test("the status is dropped once the turn ends", () async {
    app.backend.scriptedEvents = const [StatusEvent("Thinking"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    expect(app.container.read(chatControllerProvider(id)).status, isNull);
  });

  test("a status is never written to the conversation", () async {
    app.backend.scriptedEvents = const [
      StatusEvent("Running a command"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts, isEmpty);
  });

  test("a running command's output is held while it runs", () async {
    app.backend.scriptedEvents = const [
      ShellOutputEvent(callId: "c1", text: "line one\n"),
      ShellOutputEvent(callId: "c1", text: "line one\nline two\n"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("run it");
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The latest replaces the last rather than accumulating.
    expect(app.container.read(chatControllerProvider(id)).shellOutput,
        "line one\nline two\n");
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
    expect(view.shellOutput, isNull);
    // What the conversation keeps is the pair, and the pair's output.
    final stored = await app.repo.openChat(id);
    expect(stored.messages.last.parts.whereType<ToolCallPart>(), hasLength(1));
    expect(
        stored.messages.last.parts.whereType<ToolResultPart>().single.result.output,
        "files\n");
  });

  test("the turn ending takes the output away with it", () async {
    app.backend.scriptedEvents = const [
      ShellOutputEvent(text: "halfway\n"),
      DoneEvent(aborted: true),
    ];
    final (id, _) = await chatWithOneTurn("run it");

    expect(app.container.read(chatControllerProvider(id)).shellOutput, isNull);
  });

  test("a whitespace-only output is never held", () async {
    app.backend.scriptedEvents = const [
      ShellOutputEvent(text: "   \n"),
      DoneEvent(aborted: true),
    ];
    final (id, _) = await chatWithOneTurn("run it");

    expect(app.container.read(chatControllerProvider(id)).shellOutput, isNull);
  });

  test("a running command's output is never written to the conversation",
      () async {
    app.backend.scriptedEvents = const [
      ShellOutputEvent(text: "progress bar\n"),
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

    final sentAt = messagesOf(id).first.createdAt;

    await controller.regenerate(userId);
    await waitIdle(id);

    expect(messagesOf(id), hasLength(2));
    // The regenerated reply is the main agent's too — the other `_newReply`
    // call site, answered by the same `_responder`.
    expect(messagesOf(id).last.role, MessageRole.assistant);
    expect(app.backend.prompts.map((p) => p.prompt.plainText), ["hello", "hello"]);
    // The same text *and* the same date, which is what makes it the same
    // string: a regenerate re-runs the message that is already logged, so it
    // carries that message's date rather than the moment it was re-run.
    expect(app.backend.prompts.map((p) => p.prompt.createdAt), [sentAt, sentAt]);
  });

  test("regenerate from the assistant reply reruns the message above it", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final assistantId = messagesOf(id).last.id;

    await controller.regenerate(assistantId);
    await waitIdle(id);

    expect(app.backend.prompts.map((p) => p.prompt.plainText), ["hello", "hello"]);
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
    expect(messages.last.role, MessageRole.assistant);
    expect(app.backend.prompts.map((p) => p.prompt.plainText), ["helo", "hello"]);
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
    });

    test("stepping back reads the thread that was replaced", () async {
      final (id, controller, first, second) = await twoReplies();

      await controller.stepThread(second, -1);

      final chat = chatOf(id);
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
          chatOf(id).unfinished;

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
      // chats are running — see `test/CLAUDE.md`.
      app.backend.runningTurns.value = {id};
      return id;
    }

    test("interrupts the turns that are running", () async {
      final id = await runningTurn();

      await interruptLiveTurns(app.container);

      expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
    });

    test("leaves them offered to be carried on", () async {
      final id = await runningTurn();

      await interruptLiveTurns(app.container);

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

    test("carries a retryable failure on and finishes with the second round",
        () async {
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [TextDelta("now it worked"), DoneEvent()],
      ];
      final (id, controller) = await startTurn("hello");
      final reason = await controller.turnDone;

      expect(reason, TurnEnd.done);
      expect(app.backend.resumes, hasLength(1));
      expect(textOf(messagesOf(id).last), "now it worked");
      expect(app.container.read(chatControllerProvider(id)).isRunning, isFalse);
    });

    test("shows the retry row while waiting between rounds", () async {
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [DoneEvent()],
      ];
      final (id, _) = await startTurn("hello");
      await waitFor(
          () =>
              app.container.read(chatControllerProvider(id)).retry != null,
          what: "the retry row");

      expect(app.container.read(chatControllerProvider(id)).retry,
          contains("Retrying (1/5)"));
      expect(app.container.read(chatControllerProvider(id)).isRunning, isTrue);
      await waitIdle(id);
    });

    test("gives up after the setting's count and ends in error", () async {
      final (id, controller) = await failingTurn(turnRetries: 2);

      // The send plus the two rounds the setting allows.
      expect(app.backend.resumes, hasLength(2));
      expect(
          messagesOf(id).last.parts.whereType<ErrorPart>().single.message,
          contains("connection lost"));
      expect(controller.turnDone, isNull, reason: "already completed");
      expect(app.container.read(chatControllerProvider(id)).chat!.unfinished,
          isTrue);
    });

    test("stacks one error part across rounds, not one per round", () async {
      final (id, _) = await failingTurn(turnRetries: 2);

      expect(messagesOf(id).last.parts.whereType<ErrorPart>(), hasLength(1));
      // And what the log holds agrees with what the screen shows: the
      // superseding write is the only trace of the rounds after the first.
      final stored = await app.repo.openChat(id);
      expect(stored.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
    });

    test("off leaves the turn failed with no resume", () async {
      final (id, _) = await failingTurn(turnRetries: 0);

      expect(app.backend.resumes, isEmpty);
      expect(
          messagesOf(id).last.parts.whereType<ErrorPart>().single.message,
          contains("connection lost"));
    });

    test("does not retry a failure nothing can carry on from", () async {
      final (id, _) = await failingTurn(
          retryable: false, message: "No model is selected.");

      expect(app.backend.resumes, isEmpty);
      expect(messagesOf(id).last.parts.whereType<ErrorPart>(), hasLength(1));
    });

    test("a failed turn is offered to be carried on, a recovered one is not",
        () async {
      final (id, _) = await failingTurn(turnRetries: 0);

      expect(chatOf(id).unfinished, isTrue);
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

    test("notifies the failure when the app is hidden", () async {
      app.appHidden = true;
      final (id, _) = await failingTurn(
          retryable: false, message: "provider down");

      expect(app.reminderAlarms.posted, hasLength(1));
      expect(app.reminderAlarms.posted.single.chatId, id);
      expect(app.reminderAlarms.posted.single.channel, "turns");
      expect(app.reminderAlarms.posted.single.title, "New chat");
      expect(app.reminderAlarms.posted.single.body, contains("provider down"));
    });

    test("does not notify while the app is on screen", () async {
      final (_, _) = await failingTurn(retryable: false, message: "provider down");

      expect(app.reminderAlarms.posted, isEmpty);
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

    test("a reminder awaiting turnDone gets one completion, at the true end",
        () async {
      app.backend.scriptedRounds = [
        [ErrorEvent("connection lost", retryable: true), DoneEvent()],
        [TextDelta("recovered"), DoneEvent()],
      ];
      final (id, controller) = await startTurn("hello");
      final reason = await controller.turnDone;

      expect(reason, TurnEnd.done);
      expect(textOf(messagesOf(id).last), "recovered");
      expect(app.backend.resumes, hasLength(1));
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

    test("a mention resolved in byte-repair is not in the reloaded chat",
        () async {
      final app = await appWithByteRepairLibrary();
      addTearDown(app.dispose);
      final chat = await app.repo.createChat(project: "byte-repair");
      final controller =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await controller.send("@esbmc-verifier verify src.c");
      await waitIdle(chat.state.id, target: app);
      expect(
        app.backend.prompts.single.prompt.documents.keys,
        contains("@esbmc-verifier"),
      );

      await moveAndReload(app, chat.state.id, null);

      expect(
        app.container.read(chatControllerProvider(chat.state.id)).chat!.state.project,
        isNull,
      );
    });

    test("the reloaded controller composes the next message against the new project",
        () async {
      final app = await appWithByteRepairLibrary();
      addTearDown(app.dispose);
      final chat = await app.repo.createChat(project: "byte-repair");
      final controller =
          app.container.read(chatControllerProvider(chat.state.id).notifier);
      await controller.send("@esbmc-verifier verify src.c");
      await waitIdle(chat.state.id, target: app);

      await moveAndReload(app, chat.state.id, null);
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

    test("a reply is stamped with the one member the prompt addresses",
        () async {
      await _inTeam(app);
      final (id, _) =
          await chatWithOneTurn("hello @explore, find the tests", project: "team");

      final messages = messagesOf(id);
      expect(messages.first.documents, contains("@explore"));
      expect(messages.last.author, "@explore");
    });

    test("a mention list schedules the members' turns in mention order",
        () async {
      await _inTeam(app);
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
    });

    test("a command is not addressed to anyone it names", () async {
      final (id, _) = await chatWithOneTurn("!grep @explore src/");

      expect(messagesOf(id).last.author, isNull);
    });

    test("regenerating a command's reply names nobody either", () async {
      final (id, controller) = await chatWithOneTurn("!grep @explore src/");

      await controller.regenerate(messagesOf(id).last.id);
      await waitIdle(id);

      expect(messagesOf(id).last.author, isNull);
    });

    test("a regenerated reply carries the original prompt's author",
        () async {
      await _inTeam(app);
      final (id, controller) = await chatWithOneTurn(
          "hello @explore, find the tests",
          project: "team");

      await controller.regenerate(messagesOf(id).first.id);
      await waitIdle(id);

      expect(messagesOf(id).last.author, "@explore");
    });

    test("an edited resend carries the new prompt's author", () async {
      await _inTeam(app);
      final (id, controller) =
          await chatWithOneTurn("helo", project: "team");
      final userId = messagesOf(id).first.id;

      await controller.editAndResend(userId, "hello @explore");
      await waitIdle(id);

      expect(messagesOf(id).last.author, "@explore");
    });

    test("a reply naming another member hands the next turn to them", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        // Researcher's reply hands off to explore.
        const [TextDelta("let me get @explore to confirm"), DoneEvent()],
        const [TextDelta("found them"), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @explore, look at the tests", project: "team");

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

    test("the chain stops at the cap and the user resets it", () async {
      await _inTeam(app);
      // A cap of its own: the app default is ten, and three rounds is the
      // shape this test pins.
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaMaxGenerations(3);
      app.backend.scriptedRounds = [
        for (var i = 0; i < 5; i++) ...[
          const [TextDelta("see @explore"), DoneEvent()],
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

    test("a round in an Omada project opens with a mode change", () async {
      await _inTeam(app);
      final (id, _) = await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The first turn under Omada on opens the section: the opener is
      // stamped, and a reload derives the same section the page draws.
      final chat = chatOf(id);
      expect(chat.messages[0].omadaOn, isTrue);
      final reloaded = await app.repo.openChat(id);
      expect(
          entriesOf(reloaded).whereType<SectionEntry>().map((s) => s.omada),
          [true]);
    });

    test("a turn already in mode writes no second separator", () async {
      await _inTeam(app);
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));
      final sectionsBefore =
          entriesOf(await app.repo.openChat(id))
              .whereType<SectionEntry>()
              .length;

      await controller.send("plain follow-up");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // Same section: a repeat stamp of the same mode is not a flip, and
      // the reload still derives one separator.
      final sectionsAfter =
          entriesOf(await app.repo.openChat(id))
              .whereType<SectionEntry>()
              .length;
      expect(sectionsAfter, sectionsBefore);
    });

    test("a toggle off bounds the section with an off opener", () async {
      await _inTeam(app);
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmada(false);
      await controller.send("plain message");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The off turn's opener carries the flip, and the page's walk turns
      // the section off from it.
      final messages = messagesOf(id);
      expect(messages[0].omadaOn, isTrue);
      expect(messages[2].omadaOn, isFalse);
      expect(messages[3].omadaOn, isNull);
    });

    test("flipping on again opens a second section", () async {
      await _inTeam(app);
      final (id, controller) =
          await startTurn("hello @explore", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmada(false);
      await controller.send("plain message");
      await waitIdle(id, limit: const Duration(seconds: 5));
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmada(true);
      await controller.send("another message");
      await waitIdle(id, limit: const Duration(seconds: 5));

      final modes = messagesOf(id)
          .map((m) => m.omadaOn)
          .where((m) => m != null)
          .toList();
      expect(modes, [true, false, true]);
    });

    test("a member's pass ends the round", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        const [TextDelta(passWord), DoneEvent()],
      ];
      final (id, controller) =
          await startTurn("hello @explore, want this?", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The pass is on the record, and nothing followed it.
      expect(textOf(messagesOf(id).last), passWord);
      expect(app.backend.prompts, hasLength(1));
    });

    test("a pass does not cancel what the user scheduled", () async {
      await _inTeam(app);
      app.backend.scriptedRounds = [
        const [TextDelta(passWord), DoneEvent()],
        const [TextDelta("on it"), DoneEvent()],
      ];
      final (id, _) = await startTurn(
          "@explore and @build, have a look", project: "team");
      await waitIdle(id, limit: const Duration(seconds: 5));

      // Explore passed, and build's turn still ran: the user addressed
      // build directly, and a pass ends what agents hand each other, not
      // what the user asked for.
      expect(app.backend.prompts, hasLength(2));
      expect(app.backend.prompts[1].settings.omadaMember, "build");
    });

    test("parallel ordering answers with one turn per member at once",
        () async {
      await _inTeam(app);
      await app.container
          .read(projectSettingsProvider("team").notifier)
          .setOmadaOrdering(OmadaOrdering.parallel);
      // Both turns hold until this completes: a fan-out is two turns in
      // flight, not one after another.
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      final (id, _) = await startTurn(
          "@explore and @build, have a look", project: "team");

      await waitFor(() => app.backend.prompts.length >= 2,
          what: "the fan-out", limit: const Duration(seconds: 5));
      expect(app.backend.prompts[0].settings.omadaMember, "explore");
      expect(app.backend.prompts[1].settings.omadaMember, "build");

      // Tear down: the held turns finish and the round ends.
      app.backend.hold?.complete();
      app.backend.hold = null;
      await waitIdle(id, limit: const Duration(seconds: 5));
    });

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

    test("what was said while the round ran is dispatched, not re-composed",
        () async {
      await _inTeam(app);
      app.backend.hold = Completer<void>();
      addTearDown(() => app.backend.hold?.complete());
      final (id, controller) =
          await startTurn("hello @explore, take your time", project: "team");
      await waitFor(() => app.backend.prompts.isNotEmpty, what: "the turn");

      // Said while the member was speaking: on the log the moment it was
      // said, dispatched when the room settles.
      await controller.send("and @build after this");
      final chat = app.container.read(chatControllerProvider(id)).chat!;
      final queued =
          chat.messages.where((m) => textOf(m) == "and @build after this");
      expect(queued, isNotEmpty);

      app.backend.hold?.complete();
      app.backend.hold = null;
      app.backend.scriptedRounds = [
        const [TextDelta("done"), DoneEvent()],
        const [TextDelta("here too"), DoneEvent()],
      ];
      await waitIdle(id, limit: const Duration(seconds: 5));

      // The dispatched turn ran on the message the log already holds —
      // its id, not a second composition of the same words.
      final saidId = queued.single.id;
      expect(app.backend.prompts.last.prompt.id, saidId);
      expect(
          messagesOf(id).where((m) => textOf(m) == "and @build after this"),
          hasLength(1));
    });

    test("a member turn runs under the member's prompt from the library",
        () async {
      await _inTeam(app);
      final (id, _) = await startTurn("hello @explore", project: "team");
      await waitIdle(id);

      expect(app.backend.prompts.single.settings.omadaMember, "explore");
      // The mention's body rode the documents as composed, but the overlay the
      // backend words the turn under comes from the member's file plus the
      // room rule — the member's turn does not stack the mention again. The
      // history the session is filled from carries the documents as ever.
      final lastUser = app.backend.prompts.single.history;
      expect(
          lastUser.isEmpty || lastUser.last.documents["@explore"] != null,
          isTrue);
    });

    test("a plain message in an Omada project is answered by the house",
        () async {
      await _inTeam(app);
      final (id, _) =
          await chatWithOneTurn("hello", project: "team");

      expect(app.backend.prompts.single.settings.omadaMember, isNull);
      expect(messagesOf(id).last.author, isNull);
    });

    test("a mention of a name the library does not know answers by the house",
        () async {
      await _inTeam(app);
      await chatWithOneTurn("hello @nobody-knows-me", project: "team");

      expect(app.backend.prompts.single.settings.omadaMember, isNull);
    });
  });
}

/// A project with Omada on, its library the test one — the harness seeds the
/// test library for every project, so the chat's project is all a test needs.
Future<void> _inTeam(TestApp app) async {
  await app.repo.createProject("team");
  await app.container
      .read(projectSettingsProvider("team").notifier)
      .setOmada(true);
}

/// Settings with chat naming turned on. A getter, not a constant: settings are
/// mutable and each test writes its own copy.
AppSettings get _withTitleModel =>
    AppSettings(titleProviderId: "anthropic", titleModelId: "claude-haiku-3");
