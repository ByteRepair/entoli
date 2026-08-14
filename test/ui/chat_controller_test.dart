import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";

import "../fakes.dart";

void main() {
  late Directory tmp;
  late AppConfig config;
  late FakeBackend backend;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_controller_test_");
    config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);
    backend = FakeBackend();
    container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(LocalChatStore(config)),
        agentBackendProvider.overrideWithValue(backend),
        appConfigProvider.overrideWithValue(config),
        turnStallTimeoutProvider.overrideWithValue(const Duration(milliseconds: 80)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// send() returns once the prompt is dispatched; the turn ends later, on the
  /// stream's DoneEvent.
  Future<void> waitIdle(String id) async {
    for (var i = 0; i < 200; i++) {
      if (!container.read(chatControllerProvider(id)).isRunning) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail("turn never finished");
  }

  /// A chat holding one finished exchange, plus its controller.
  Future<(String, ChatController)> chatWithOneTurn(String text) async {
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await container.read(chatRepositoryProvider).save(chat);
    // Let the controller's initial load settle before driving it.
    await Future<void>.delayed(Duration.zero);
    await controller.send(text);
    await waitIdle(id);
    return (id, controller);
  }

  List<Message> messagesOf(String id) => container.read(chatControllerProvider(id)).chat!.messages;

  String textOf(Message m) => m.parts.whereType<TextPart>().map((p) => p.text).join();

  test("send appends the user message and an assistant reply", () async {
    final (id, _) = await chatWithOneTurn("hello");

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.first.role, MessageRole.user);
    expect(textOf(messages.first), "hello");
    expect(backend.prompts.single.text, "hello");
  });

  test("a backend error becomes an error part on the reply", () async {
    backend.scriptedEvents = const [ErrorEvent("APIError (HTTP 429): usage limit"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    final reply = messagesOf(id).last;
    expect(reply.role, MessageRole.assistant);
    expect(reply.parts.whereType<ErrorPart>().single.message, contains("usage limit"));
    expect(container.read(chatControllerProvider(id)).isRunning, isFalse);
  });

  test("a retry shows up as a notice while the turn is still running", () async {
    backend.scriptedEvents = const [
      RetryEvent(attempt: 2, message: "you have reached your session usage limit"),
    ];
    backend.hold = Completer<void>();
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send("hello");
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final view = container.read(chatControllerProvider(id));
    expect(view.retry, contains("usage limit"));
    expect(view.retry, contains("Attempt 2"));
    expect(view.isRunning, isTrue);
    backend.hold!.complete();
  });

  test("the retry notice is dropped once the turn ends", () async {
    backend.scriptedEvents = const [
      RetryEvent(attempt: 1, message: "rate limited"),
      ErrorEvent("APIError (HTTP 429): rate limited"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final view = container.read(chatControllerProvider(id));
    expect(view.retry, isNull);
    expect(view.chat!.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
  });

  test("a retry is never written to the conversation", () async {
    backend.scriptedEvents = const [
      RetryEvent(attempt: 1, message: "rate limited"),
      DoneEvent(),
    ];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await container.read(chatRepositoryProvider).openChat(id);
    expect(stored.messages.last.parts, isEmpty);
  });

  test("a turn that produces nothing is given up on, blaming the last retry", () async {
    backend.scriptedEvents = const [
      RetryEvent(attempt: 3, message: "you have reached your session usage limit"),
    ];
    backend.hold = Completer<void>();
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);

    await controller.send("hello");
    await waitIdle(id);

    final view = container.read(chatControllerProvider(id));
    final error = view.chat!.messages.last.parts.whereType<ErrorPart>().single;
    expect(error.message, contains("Gave up"));
    expect(error.message, contains("usage limit"));
    expect(view.retry, isNull);
    expect(backend.aborted, [id]);
    backend.hold!.complete();
  });

  test("giving up says so plainly when nothing explained the stall", () async {
    backend.scriptedEvents = const [];
    backend.hold = Completer<void>();
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);

    await controller.send("hello");
    await waitIdle(id);

    final error = container
        .read(chatControllerProvider(id))
        .chat!
        .messages
        .last
        .parts
        .whereType<ErrorPart>()
        .single;
    expect(error.message, contains("No response after"));
    backend.hold!.complete();
  });

  test("output keeps a slow but working turn alive", () async {
    // Deltas spaced under the timeout: each one buys the turn more time.
    backend.scriptedEvents = const [TextDelta("thinking")];
    backend.hold = Completer<void>();
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);

    await controller.send("hello");
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final view = container.read(chatControllerProvider(id));
    expect(view.isRunning, isTrue);
    expect(view.chat!.messages.last.parts.whereType<ErrorPart>(), isEmpty);
    backend.hold!.complete();
  });

  test("a given-up turn can be retried, and the retry stands alone", () async {
    backend.scriptedEvents = const [RetryEvent(attempt: 1, message: "rate limited")];
    backend.hold = Completer<void>();
    final chat = await container.read(chatRepositoryProvider).createChat();
    final id = chat.state.id;
    final controller = container.read(chatControllerProvider(id).notifier);
    await Future<void>.delayed(Duration.zero);
    await controller.send("hello");
    await waitIdle(id);

    backend.hold!.complete();
    backend.hold = null;
    backend.scriptedEvents = const [TextDelta("hi"), DoneEvent()];
    await controller.regenerate(messagesOf(id).last.id);
    await waitIdle(id);

    final messages = messagesOf(id);
    expect(messages, hasLength(2));
    expect(messages.last.parts.whereType<ErrorPart>(), isEmpty);
    expect(textOf(messages.last), "hi");
  });

  test("an errored reply is persisted with the chat", () async {
    backend.scriptedEvents = const [ErrorEvent("APIError (HTTP 429): usage limit"), DoneEvent()];
    final (id, _) = await chatWithOneTurn("hello");

    final stored = await container.read(chatRepositoryProvider).openChat(id);
    expect(stored.messages.last.parts.whereType<ErrorPart>(), hasLength(1));
  });

  test("regenerate resends the same text and drops the old reply", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final userId = messagesOf(id).first.id;

    await controller.regenerate(userId);
    await waitIdle(id);

    expect(messagesOf(id), hasLength(2));
    expect(backend.prompts.map((p) => p.text), ["hello", "hello"]);
  });

  test("regenerate from the assistant reply reruns the message above it", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final assistantId = messagesOf(id).last.id;

    await controller.regenerate(assistantId);
    await waitIdle(id);

    expect(backend.prompts.map((p) => p.text), ["hello", "hello"]);
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
    expect(backend.prompts.map((p) => p.text), ["helo", "hello"]);
  });

  test("a resend starts a fresh session seeded with the kept messages", () async {
    final (id, controller) = await chatWithOneTurn("first");
    await controller.send("second");
    await waitIdle(id);
    final secondId = messagesOf(id)[2].id;

    await controller.regenerate(secondId);
    await waitIdle(id);

    expect(backend.resets, hasLength(1));
    expect(backend.resets.single, contains("first"));
    expect(backend.resets.single, isNot(contains("second")));
  });

  test("the truncated conversation is persisted, not just held in memory", () async {
    final (id, controller) = await chatWithOneTurn("hello");
    final userId = messagesOf(id).first.id;

    await controller.editAndResend(userId, "goodbye");
    await waitIdle(id);

    final stored = await container.read(chatRepositoryProvider).openChat(id);
    expect(stored.messages, hasLength(2));
    expect(textOf(stored.messages.first), "goodbye");
  });
}
