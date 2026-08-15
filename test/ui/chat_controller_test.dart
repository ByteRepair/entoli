import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// Give whatever is still in flight a chance to land.
  Future<void> waitFor(bool Function() done, {String what = "it"}) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
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
      expect(app.config.stateFile(chat.state.id).existsSync(), isFalse);
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

  test("regenerate resends the same text and drops the old reply", () async {
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

  test("an attachment is saved, recorded on the message and sent with it", () async {
    final (id, _) = await chatWithOneTurn(
      "look",
      attachments: [testAttachment("shot.png", mimeType: "image/png")],
    );

    final file = (await app.repo.openChat(id)).messages.first.parts.whereType<FilePart>().single;
    expect(file.filename, "shot.png");
    expect(file.mimeType, "image/png");
    expect(app.config.resourcesDir(id).listSync(), hasLength(1));
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
    expect(app.config.resourcesDir(id).listSync(), hasLength(1));
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

  test("the truncated conversation is persisted, not just held in memory", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final userId = messagesOf(id).first.id;

    await controller.editAndResend(userId, "goodbye");
    await waitIdle(id);

    final stored = await app.repo.openChat(id);
    expect(stored.messages, hasLength(2));
    expect(textOf(stored.messages.first), "goodbye");
  });
}

/// Settings with chat naming turned on. A getter, not a constant: settings are
/// mutable and each test writes its own copy.
AppSettings get _withTitleModel =>
    AppSettings(titleProviderId: "anthropic", titleModelId: "claude-haiku-3");
