import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
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
import "package:agent_chat/ui/voice/widgets/voice_controls.dart";

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

  setUp(() => app = TestApp.create(voiceModels: voiceModelIds));
  tearDown(() => app.dispose());

  /// Voice mode running over a chat of its own, with the two models picked.
  /// The chat is seeded rather than drafted, and the wait is not decoration:
  /// the controller loads it asynchronously, and driving one that has not
  /// finished loading is a `send` that quietly does nothing.
  Future<String> startVoice() async {
    await app.pickVoiceModels();
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
    await app.pickVoiceModels();
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

    testWidgets("fades into the orb above it", (tester) async {
      final lines = [
        for (var i = 0; i < 5; i++)
          const VoiceLine(VoiceLineKind.replied, "wwwwwwwwww"),
      ];
      await app.pump(
        tester,
        Center(
          child: RepaintBoundary(
            key: const ValueKey("window"),
            child: SizedBox(width: 200, child: TranscriptWindow(lines: lines)),
          ),
        ),
      );

      // Painted rather than asserted about: what the mask is for is the top of
      // the *view* being faint, and a blend mode on its own would pass with
      // the gradient upside down.
      final painted = await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey("window")));
        final image = await boundary.toImage();
        return image.toByteData();
      });
      const width = 200;
      const line = TranscriptWindow.lineHeight;
      int densest(double from, double to) {
        var most = 0;
        for (var y = from.round(); y < to.round(); y++) {
          for (var x = 0; x < width; x++) {
            final alpha = painted!.getUint8((y * width + x) * 4 + 3);
            if (alpha > most) most = alpha;
          }
        }
        return most;
      }

      final top = densest(2, line - 2);
      final bottom = densest(line * 4 + 2, line * 5 - 2);
      expect(bottom, greaterThan(200), reason: "the newest line is the one being read");
      expect(top, lessThan(bottom ~/ 2), reason: "the oldest fades out of the window");
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

  group("the controls", () {
    Future<void> pumpControls(WidgetTester tester, VoiceViewState state,
            {VoidCallback? onDone, ValueChanged<bool>? onTalk}) =>
        app.pump(
          tester,
          Scaffold(
            body: VoiceControls(
              state: state,
              onMute: () {},
              onTalk: onTalk ?? (_) {},
              onStop: () {},
              onDone: onDone ?? () {},
            ),
          ),
        );

    testWidgets("stop is dead unless there is a reply to stop", (tester) async {
      await pumpControls(
          tester, const VoiceViewState(status: VoiceStatus.listening));
      expect(enabled(tester, buttonTipped("Stop the reply")), isFalse);

      await pumpControls(
          tester, const VoiceViewState(status: VoiceStatus.speaking));
      expect(enabled(tester, buttonTipped("Stop the reply")), isTrue);
    });

    testWidgets("the microphone button says which way it goes", (tester) async {
      await pumpControls(
          tester, const VoiceViewState(status: VoiceStatus.listening));
      expect(find.text("Mute"), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);

      await pumpControls(tester,
          const VoiceViewState(status: VoiceStatus.listening, paused: true));
      expect(find.text("Listen"), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    });

    testWidgets("touch to speak puts Talk where the microphone button was",
        (tester) async {
      final held = <bool>[];
      await pumpControls(
        tester,
        const VoiceViewState(
            status: VoiceStatus.listening, paused: true, pushToTalk: true),
        onTalk: held.add,
      );
      expect(find.text("Mute"), findsNothing);
      expect(find.text("Talk"), findsOneWidget);

      // Down and up rather than a tap: the microphone is open for as long as
      // the finger is on it.
      final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip("Hold to talk")));
      await tester.pump();
      expect(held, [true]);

      await gesture.up();
      await tester.pump();
      expect(held, [true, false]);
    });

    testWidgets("done is offered whatever the session is doing", (tester) async {
      var left = 0;
      // Off is the state a page that failed to start is left in, and leaving
      // is the only thing there is to do about it.
      await pumpControls(tester, const VoiceViewState(), onDone: () => left++);
      expect(enabled(tester, buttonTipped("Shut the microphone")), isFalse);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pump();
      expect(left, 1);
    });
  });

  testWidgets("Mute shuts the microphone from the screen", (tester) async {
    await io(tester, app.pickVoiceModels);
    final chat = await io(tester, app.seedChat);
    await app.pump(tester, VoicePage(chatId: chat.state.id), settle: false);
    await pumpUntil(tester, find.text("LISTENING"));

    await tester.tap(find.byIcon(Icons.mic_none));
    await pumpUntil(tester, find.text("Listen"));

    expect(app.voice.session!.listening, isFalse);
    expect(find.text("PAUSED"), findsOneWidget);
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

    test("shuts the microphone and nothing else: the reply goes on", () async {
      app.backend.scriptedEvents = [
        const TextDelta("A whole sentence. "),
        const DoneEvent(),
      ];
      final id = await startVoice();
      app.voice.session!.hear("say something");
      await waitFor(() => app.voice.session!.spoken.isNotEmpty,
          what: "the reply to start being read");

      await app.container.read(voiceControllerProvider(id).notifier).setPaused(true);

      expect(app.voice.session!.hushed, 0,
          reason: "mute is about what the phone hears, not what it is saying");
      expect(app.container.read(voiceControllerProvider(id)).status,
          VoiceStatus.speaking);
    });
  });

  group("touch to speak", () {
    Future<void> turnOn() =>
        app.container.read(appSettingsProvider.notifier).setVoicePushToTalk(true);

    test("a session opens with the microphone shut", () async {
      await turnOn();
      final id = await startVoice();

      expect(app.voice.session!.listening, isFalse);
      final view = app.container.read(voiceControllerProvider(id));
      expect(view.paused, isTrue);
      expect(view.pushToTalk, isTrue);
      expect(view.word, "Ready", reason: "nobody paused it");
    });

    test("holding opens the microphone and stops the reply", () async {
      app.backend.scriptedEvents = [
        const TextDelta("A long answer. "),
        const DoneEvent(),
      ];
      await turnOn();
      final id = await startVoice();
      final voice = app.container.read(voiceControllerProvider(id).notifier);

      // Held once to say something, which is the only way in with the
      // microphone shut.
      await voice.talk(true);
      app.voice.session!.hear("go on then");
      await waitFor(() => app.voice.session!.spoken.isNotEmpty,
          what: "the reply to start being read");

      await voice.talk(true);
      expect(app.voice.session!.hushed, greaterThan(0),
          reason: "whoever holds the button down is about to talk over it");
      expect(app.voice.session!.listening, isTrue);
    });

    test("releasing keeps the sentence it was held for", () async {
      await turnOn();
      final id = await startVoice();
      final voice = app.container.read(voiceControllerProvider(id).notifier);

      await voice.talk(true);
      await voice.talk(false);

      expect(app.voice.session!.listening, isFalse);
      expect(app.voice.session!.finished, 1);
      expect(app.container.read(voiceControllerProvider(id)).paused, isTrue);
    });

    test("turning it off under a running session opens the microphone",
        () async {
      await turnOn();
      final id = await startVoice();
      expect(app.voice.session!.listening, isFalse);

      await app.container
          .read(appSettingsProvider.notifier)
          .setVoicePushToTalk(false);
      await waitFor(() => app.voice.session!.listening,
          what: "the microphone to open");

      final view = app.container.read(voiceControllerProvider(id));
      expect(view.pushToTalk, isFalse);
      expect(view.paused, isFalse);
    });
  });

  group("reading one message out", () {
    Future<void> pickSpeech() => app.pickVoiceModels();

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

    // Pressing it reads this rather than watching it, so an answer that is
    // only right once a disk scan has finished is one the first press gets
    // wrong. Read with nothing pumped, which is where that used to show.
    test("is ready to be pressed before anything has been drawn", () async {
      await app.pickVoiceModels();
      expect(app.container.read(voiceReadyProvider), isTrue);
    });
  });

  testWidgets("with no models picked the page says so rather than opening silent",
      (tester) async {
    final chat = await io(tester, app.seedChat);
    await app.pump(tester, VoicePage(chatId: chat.state.id), settle: false);
    await tester.pump();

    expect(find.byType(VoiceBloom), findsOneWidget);
    expect(find.byType(TranscriptWindow), findsOneWidget);
    expect(find.textContaining("Settings"), findsOneWidget);
  });
}
