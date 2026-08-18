import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/voice/read_aloud.dart";
import "package:agent_chat/ui/voice/transcript.dart";
import "package:agent_chat/ui/voice/voice_controller.dart";
import "package:agent_chat/ui/voice/voice_page.dart";
import "package:agent_chat/ui/voice/widgets/transcript_window.dart";
import "package:agent_chat/ui/chat/widgets/resume_bar.dart";
import "package:agent_chat/ui/voice/widgets/voice_bloom.dart";

import "../harness.dart";

/// A turn that has both said something and stopped. `isRunning` alone is false
/// before it starts as well as after it ends.
bool _finished(TestApp app, String id) {
  final view = app.container.read(chatControllerProvider(id));
  return !view.isRunning && (view.chat?.messages.length ?? 0) >= 2;
}

/// What the orb is drawn from, which is where everything it is told ends up.
BloomPainter _bloom(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is BloomPainter))
    .painter! as BloomPainter;

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create(
        voiceModels: const {"whisper-tiny", "piper-en_US-amy"},
      ));
  tearDown(() => app.dispose());

  /// Voice mode running over a chat of its own, with the two models picked.
  /// The chat is seeded rather than drafted, and the wait is not decoration:
  /// the controller loads it asynchronously, and driving one that has not
  /// finished loading is a `send` that quietly does nothing.
  Future<String> startVoice() async {
    final settings = app.container.read(appSettingsProvider.notifier);
    await settings.setVoiceRecognitionModel("whisper-tiny");
    await settings.setVoiceSpeechModel("piper-en_US-amy");
    final chat = await app.seedChat();
    final id = chat.state.id;
    await waitFor(() => app.container.read(chatControllerProvider(id)).chat != null,
        what: "the chat to load");
    await app.container.read(voiceControllerProvider(id).notifier).start();
    return id;
  }

  group("a spoken turn", () {
    test("is an ordinary turn: same records, same log", () async {
      app.backend.scriptedEvents = [
        const TextDelta("Right away."),
        const DoneEvent(),
      ];
      final id = await startVoice();
      app.voice.session!.hear("list the files");
      await waitFor(() => _finished(app, id), what: "the turn");

      final chat = await app.store.load(id);
      expect(chat.messages.map((m) => m.role),
          [MessageRole.user, MessageRole.assistant]);
      expect(chat.messages.first.plainText, "list the files");
      expect(chat.messages.last.plainText, "Right away.");
      // Closed like any other turn, so a reload does not offer to continue it.
      expect(chat.unfinished, isFalse);
    });

    test("is spoken a sentence at a time, and only what was said",
        () async {
      app.backend.scriptedEvents = [
        const ReasoningDelta("thinking about it"),
        const ReasoningEnd(text: "thinking about it"),
        const TextDelta("Two files. "),
        const TextDelta("Both are Dart.\n```sh\nls -l\n```\n"),
        const DoneEvent(),
      ];
      final id = await startVoice();
      app.voice.session!.hear("what is here");
      await waitFor(() => _finished(app, id), what: "the turn");
      await waitFor(() => app.voice.session!.spoken.length >= 2,
          what: "both sentences");

      expect(app.voice.session!.spoken, ["Two files.", "Both are Dart."]);
    });
  });

  test("talking over the reply stops it and abandons the turn",
      () async {
    final held = Completer<void>();
    // No DoneEvent: the turn is left open on the hold, the way a real one is
    // while the backend is still working. With one, it would be over before
    // there was anything to talk over.
    app.backend
      ..scriptedEvents = [const TextDelta("A long answer. ")]
      ..hold = held;
    final id = await startVoice();
    app.voice.session!.hear("go on then");
    // Not merely running: a reply cannot be talked over until it has started
    // saying something, and waiting for that is also what puts this past the
    // turn's own opening writes.
    await waitFor(() {
      final view = app.container.read(chatControllerProvider(id));
      return view.isRunning && (view.chat?.messages.last.hasText ?? false);
    }, what: "the reply to start");

    app.voice.session!.interrupt();
    await waitFor(
        () => !app.container.read(chatControllerProvider(id)).isRunning,
        what: "the turn to be abandoned");
    held.complete();

    final chat = await app.store.load(id);
    // Stopped, not finished: an aborted turn is not one to offer to resume.
    expect(chat.unfinished, isFalse);
    expect(chat.messages.last.plainText.trim(), "A long answer.");
  });

  test("a reply that was already written is not read out on the way in", () async {
    await app.container.read(appSettingsProvider.notifier)
        .setVoiceRecognitionModel("whisper-tiny");
    await app.container.read(appSettingsProvider.notifier)
        .setVoiceSpeechModel("piper-en_US-amy");
    final made = await app.repo.createChat();
    await app.writeChat(
      made.copyWith(messages: [
        Message(
          id: "u",
          role: MessageRole.user,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "what is here")],
        ),
        Message(
          id: "a",
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "Two files. Both are Dart.")],
        ),
      ]),
      finished: false,
    );
    final id = made.state.id;
    await waitFor(() => app.container.read(chatControllerProvider(id)).chat != null,
        what: "the chat to load");
    await app.container.read(voiceControllerProvider(id).notifier).start();
    await Future<void>.delayed(Duration.zero);

    // Entering voice mode over a finished reply, or carrying on an interrupted
    // turn, must not read what is already there back from the top.
    expect(app.voice.session!.spoken, isEmpty);
  });

  test("the process is held open while listening, and let go after", () async {
    final id = await startVoice();
    expect(app.work.listened, [true]);

    await app.container.read(voiceControllerProvider(id).notifier).stop();
    // Released, not merely abandoned: a hold nobody lets go of leaves the
    // notification up and the cached engine never evicted again.
    expect(app.work.listened, [true, false]);
  });

  test("the notification's Stop leaves voice mode and nothing else", () async {
    final id = await startVoice();

    app.work.stop(BackgroundJob.voice);
    await waitFor(
        () => app.container.read(voiceControllerProvider(id)).status == VoiceStatus.off,
        what: "voice mode to stop");
    expect(app.voice.session!.disposed, isTrue);
  });

  test("hushing stops the speech without leaving voice mode", () async {
    final id = await startVoice();
    final voice = app.container.read(voiceControllerProvider(id).notifier);

    await voice.hush();

    expect(app.voice.session!.hushed, 1);
    expect(app.container.read(voiceControllerProvider(id)).status, isNot(VoiceStatus.off));
  });

  test("falling silent goes back to listening", () async {
    final id = await startVoice();
    app.voice.session!.fallSilent();
    await Future<void>.delayed(Duration.zero);

    expect(app.container.read(voiceControllerProvider(id)).status, VoiceStatus.listening);
  });

  test("a failure mid-session says what it was", () async {
    final id = await startVoice();
    app.voice.session!.fail("the microphone was taken");
    await waitFor(
        () => app.container.read(voiceControllerProvider(id)).status == VoiceStatus.failed,
        what: "the failure");

    expect(app.container.read(voiceControllerProvider(id)).error,
        contains("microphone was taken"));
  });

  test("leaving voice mode closes the session", () async {
    final id = await startVoice();
    final session = app.voice.session!;
    expect(session.disposed, isFalse);

    await app.container.read(voiceControllerProvider(id).notifier).stop();
    expect(session.disposed, isTrue);
    expect(app.container.read(voiceControllerProvider(id)).status, VoiceStatus.off);
  });

  test("a model that will not load says so rather than opening silent",
      () async {
    app.voice.refusal = "Entoli was not allowed to use the microphone.";
    final id = await startVoice();

    final state = app.container.read(voiceControllerProvider(id));
    expect(state.status, VoiceStatus.failed);
    expect(state.error, contains("microphone"));
  });

  group("the transcript", () {
    testWidgets("holds five lines whatever the text scale", (tester) async {
      final lines = [
        for (var i = 0; i < 20; i++) VoiceLine(VoiceLineKind.said, "line $i"),
      ];
      await app.pump(
        tester,
        Scaffold(body: TranscriptWindow(lines: lines)),
      );
      final box = tester.getSize(find.byType(TranscriptWindow));
      expect(box.height, TranscriptWindow.lineHeight * TranscriptWindow.visibleLines);
    });

    testWidgets("scrolls back to what was said at the start", (tester) async {
      final lines = [
        for (var i = 0; i < 20; i++) VoiceLine(VoiceLineKind.said, "line $i"),
      ];
      await app.pump(tester, Scaffold(body: TranscriptWindow(lines: lines)));

      final scrollable = find.descendant(
        of: find.byType(TranscriptWindow),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable, const Offset(0, 800));
      await tester.pumpAndSettle();
      expect(find.text("line 0"), findsOneWidget);
    });

    testWidgets("says who said what", (tester) async {
      final lines = Transcript().of([
        Message(
          id: "u",
          role: MessageRole.user,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "what is here")],
        ),
        Message(
          id: "a",
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          parts: const [
            MessagePart.reasoning(text: "not this"),
            MessagePart.toolCall(
                toolCall: ToolCall(id: "1", name: "bash", argumentsText: "ls")),
            MessagePart.text(text: "Two files."),
          ],
        ),
      ]);
      expect(lines.map((l) => (l.kind, l.text)), [
        (VoiceLineKind.said, "what is here"),
        (VoiceLineKind.activity, "Ran a command"),
        (VoiceLineKind.replied, "Two files."),
      ]);
    });
  });

  testWidgets("an interrupted turn is offered to be carried on here too",
      (tester) async {
    final chat = await io(tester, () async {
      final made = await app.repo.createChat();
      final full = made.copyWith(messages: [
        Message(
          id: "u",
          role: MessageRole.user,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "go on")],
        ),
        Message(
          id: "a",
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          parts: const [MessagePart.text(text: "Half a")],
        ),
      ]);
      await app.writeChat(full, finished: false);
      return full;
    });
    await app.pump(tester, VoicePage(chatId: chat.state.id), settle: false);
    await pumpUntil(tester, find.byType(ResumeBar));

    // The screen where a turn is most likely to be cut off, since talking over
    // a reply aborts it.
    expect(find.byType(ResumeBar), findsOneWidget);
  });

  testWidgets("the orb follows a live level", (tester) async {
    final level = ValueNotifier(0.0);
    addTearDown(level.dispose);
    await app.pump(
      tester,
      Scaffold(
        body: VoiceBloom(
          state: VoiceViewState(status: VoiceStatus.listening, level: level),
        ),
      ),
      settle: false,
    );

    await tester.pump();
    expect(_bloom(tester).level, 0);

    level.value = 1;
    await tester.pump();
    expect(_bloom(tester).level, 1);
  });

  group("pausing", () {
    test("shuts the microphone, and opens it again", () async {
      final id = await startVoice();
      final voice = app.container.read(voiceControllerProvider(id).notifier);

      await voice.setPaused(true);
      expect(app.voice.session!.listening, isFalse,
          reason: "paused has to mean the device has stopped recording");
      expect(app.container.read(voiceControllerProvider(id)).paused, isTrue);

      await voice.setPaused(false);
      expect(app.voice.session!.listening, isTrue);
      expect(app.container.read(voiceControllerProvider(id)).paused, isFalse);
    });

    test("a fresh session is listening, whatever the last one was doing",
        () async {
      final id = await startVoice();
      final voice = app.container.read(voiceControllerProvider(id).notifier);
      await voice.setPaused(true);
      await voice.stop();

      await voice.start();
      expect(app.container.read(voiceControllerProvider(id)).paused, isFalse);
    });
  });

  group("reading one message out", () {
    Future<void> pickSpeech() => app.container
        .read(appSettingsProvider.notifier)
        .setVoiceSpeechModel("piper-en_US-amy");

    test("speaks it with no microphone open", () async {
      await pickSpeech();
      final failed = await app.container
          .read(readAloudProvider.notifier)
          .toggle("m1", "Hello there. How are you?");

      expect(failed, isNull);
      // The whole of what makes this not voice mode.
      expect(app.voice.listeningWith, isNull);
      expect(app.voice.session!.spoken.join(" "),
          "Hello there. How are you?");
      expect(app.container.read(readAloudProvider), "m1");
    });

    test("pressing the same one again stops it", () async {
      await pickSpeech();
      final reader = app.container.read(readAloudProvider.notifier);
      await reader.toggle("m1", "One.");
      final session = app.voice.session!;

      await reader.toggle("m1", "One.");
      expect(app.container.read(readAloudProvider), isNull);
      expect(session.disposed, isTrue);
    });

    test("the model is let go once the message has been read", () async {
      await pickSpeech();
      await app.container.read(readAloudProvider.notifier).toggle("m1", "One.");
      final session = app.voice.session!;

      session.fallSilent();
      await waitFor(() => session.disposed, what: "the session to be let go");
      expect(app.container.read(readAloudProvider), isNull);
    });

    test("with no speech model picked it says so rather than opening silent",
        () async {
      final failed =
          await app.container.read(readAloudProvider.notifier).toggle("m1", "One.");

      expect(failed, isNotNull);
      expect(app.voice.session, isNull);
    });
  });

  testWidgets("a paused orb is the microphone shut, and does not follow it",
      (tester) async {
    final level = ValueNotifier(0.0);
    addTearDown(level.dispose);
    await app.pump(
      tester,
      Scaffold(
        body: VoiceBloom(
          state: VoiceViewState(
              status: VoiceStatus.listening, level: level, paused: true),
        ),
      ),
    );

    expect(find.text("PAUSED"), findsOneWidget);
    level.value = 1;
    await tester.pump();
    expect(_bloom(tester).level, 0,
        reason: "a shut microphone is not something to draw a voice from");
    // Nothing is moving either, which is the whole of what a wake lock held
    // over a shut microphone would otherwise be spent on.
    expect(tester.binding.transientCallbackCount, 0);
  });

  group("the composer's voice button", () {
    Future<void> pumpComposer(WidgetTester tester, TextEditingController text) =>
        app.pump(
          tester,
          Scaffold(
            body: Composer(
              controller: text,
              isRunning: false,
              onSend: (_, _) {},
              onAbort: () {},
              onVoice: () {},
            ),
          ),
        );

    testWidgets("goes when there is a message to send instead", (tester) async {
      final text = TextEditingController();
      addTearDown(text.dispose);
      await pumpComposer(tester, text);
      expect(find.byTooltip("Voice mode"), findsOneWidget);

      await tester.enterText(find.byType(TextField), "hello");
      await tester.pumpAndSettle();
      expect(find.byTooltip("Voice mode"), findsNothing);

      await tester.enterText(find.byType(TextField), "");
      await tester.pumpAndSettle();
      expect(find.byTooltip("Voice mode"), findsOneWidget);
    });

    testWidgets("whitespace is not a message", (tester) async {
      final text = TextEditingController();
      addTearDown(text.dispose);
      await pumpComposer(tester, text);

      await tester.enterText(find.byType(TextField), "   ");
      await tester.pumpAndSettle();
      expect(find.byTooltip("Voice mode"), findsOneWidget);
    });
  });

  testWidgets("with no models picked the page says so rather than opening silent",
      (tester) async {
    final chat = await tester.runAsync(app.seedChat);
    await app.pump(tester, VoicePage(chatId: chat!.state.id), settle: false);
    await tester.pump();

    expect(find.byType(VoiceBloom), findsOneWidget);
    expect(find.byType(TranscriptWindow), findsOneWidget);
    expect(find.textContaining("Settings"), findsOneWidget);
  });
}
