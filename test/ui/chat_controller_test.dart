import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create(stallTimeout: const Duration(milliseconds: 80)));
  tearDown(() => app.dispose());

  /// send() returns once the prompt is dispatched; the turn ends later, on the
  /// stream's DoneEvent.
  Future<void> waitIdle(String id) async {
    for (var i = 0; i < 200; i++) {
      if (!app.container.read(chatControllerProvider(id)).isRunning) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail("turn never finished");
  }

  /// A chat with a turn under way. The delay lets the controller's initial
  /// load settle before it is driven.
  Future<(String, ChatController)> startTurn(String text) async {
    final chat = await app.repo.createChat();
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send(text);
    return (id, controller);
  }

  /// A chat holding one finished exchange, plus its controller.
  Future<(String, ChatController)> chatWithOneTurn(String text) async {
    final (id, controller) = await startTurn(text);
    await waitIdle(id);
    return (id, controller);
  }

  List<Message> messagesOf(String id) => app.container.read(chatControllerProvider(id)).chat!.messages;

  String textOf(Message m) => m.parts.whereType<TextPart>().map((p) => p.text).join();

  test("send appends the user message and an assistant reply", () async {
    final (id, _) = await chatWithOneTurn("hello");

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(textOf(messages.first), "hello");
    expect(app.backend.prompts.single.text, "hello");
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

  test("a turn that produces nothing is given up on, blaming the last retry", () async {
    app.backend.scriptedEvents = const [
      RetryEvent(attempt: 3, message: "you have reached your session usage limit"),
    ];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await waitIdle(id);

    final view = app.container.read(chatControllerProvider(id));
    final error = view.chat!.messages.last.parts.whereType<ErrorPart>().single;
    expect(error.message, contains("Gave up"));
    expect(error.message, contains("usage limit"));
    expect(view.retry, isNull);
    expect(app.backend.aborted, [id]);
    app.backend.hold!.complete();
  });

  test("giving up says so plainly when nothing explained the stall", () async {
    app.backend.scriptedEvents = const [];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await waitIdle(id);

    final error = app.container
        .read(chatControllerProvider(id))
        .chat!
        .messages
        .last
        .parts
        .whereType<ErrorPart>()
        .single;
    expect(error.message, contains("No response after"));
    app.backend.hold!.complete();
  });

  test("output keeps a slow but working turn alive", () async {
    // Deltas spaced under the timeout: each one buys the turn more time.
    app.backend.scriptedEvents = const [TextDelta("thinking")];
    app.backend.hold = Completer<void>();
    final (id, _) = await startTurn("hello");
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final view = app.container.read(chatControllerProvider(id));
    expect(view.isRunning, isTrue);
    expect(view.chat!.messages.last.parts.whereType<ErrorPart>(), isEmpty);
    app.backend.hold!.complete();
  });

  test("a given-up turn can be retried, and the retry stands alone", () async {
    app.backend.scriptedEvents = const [RetryEvent(attempt: 1, message: "rate limited")];
    app.backend.hold = Completer<void>();
    final (id, controller) = await startTurn("hello");
    await waitIdle(id);

    app.backend.hold!.complete();
    app.backend.hold = null;
    app.backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    await controller.regenerate(messagesOf(id).last.id);
    await waitIdle(id);

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.last.parts.whereType<ErrorPart>(), isEmpty);
    expect(textOf(messages.last), "hi");
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
    final chat = await app.repo.createChat();
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);

    await controller.send("look", attachments: [testAttachment("shot.png", mimeType: "image/png")]);
    await waitIdle(id);

    final file = (await app.repo.openChat(id)).messages.first.parts.whereType<FilePart>().single;
    expect(file.filename, "shot.png");
    expect(file.mimeType, "image/png");
    expect(app.config.resourcesDir(id).listSync(), hasLength(1));
    expect(app.backend.prompts.single.attachments.single.bytes, [104, 105]);
  });

  test("regenerating sends the attachments again, from disk", () async {
    final chat = await app.repo.createChat();
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send("look", attachments: [testAttachment("shot.png", mimeType: "image/png")]);
    await waitIdle(id);

    await controller.regenerate(messagesOf(id).first.id);
    await waitIdle(id);

    expect(app.backend.prompts.map((p) => p.attachments.single.filename), ["shot.png", "shot.png"]);
    expect(messagesOf(id).first.parts.whereType<FilePart>(), hasLength(1));
    // The same file, not a second copy of it.
    expect(app.config.resourcesDir(id).listSync(), hasLength(1));
  });

  test("editing the text keeps what the message carried", () async {
    final chat = await app.repo.createChat();
    final id = chat.state.id;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send("look", attachments: [testAttachment("notes.txt")]);
    await waitIdle(id);

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
