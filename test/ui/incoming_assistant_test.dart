import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/assistant_view.dart";
import "package:agent_chat/ui/assistant/incoming_assistant.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/voice/voice_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  // The wrapper over something standing in for the app, since what is under
  // test is a chat opened over whatever was on screen. [settle] is off where
  // the launch opens voice mode: the orb never comes to rest.
  Future<void> start(WidgetTester tester, {bool settle = true}) async {
    await app.pump(
      tester,
      const IncomingAssistant(child: Scaffold(body: Text("whatever was up"))),
      settle: settle,
    );
    if (settle) await settleIo(tester);
  }

  /// The app started with [settings] written down and a launch waiting, which
  /// is the gesture that started the app. The order matters — the settings have
  /// to be on disk before the first frame reads them — so it is established
  /// once here rather than at each test.
  Future<void> launchWith(
    WidgetTester tester,
    AppSettings settings, {
    bool settle = true,
  }) async {
    await io(tester, () => app.seedSettings(settings));
    app.assistant.pending = true;
    await start(tester, settle: settle);
  }

  String? openedChat() => app.container.read(selectedChatIdProvider);
  String? openedProject() => app.container.read(selectedProjectProvider).project;

  testWidgets("nothing opens when the gesture never happened", (tester) async {
    app = TestApp.create();
    await io(tester, app.openSomeChat);
    final was = openedChat();
    await start(tester);

    expect(openedChat(), was);
  });

  testWidgets("a launch waiting at startup opens the new-chat screen",
      (tester) async {
    app = TestApp.create();
    await io(tester, app.openSomeChat);
    app.assistant.pending = true;
    await start(tester);

    expect(openedChat(), isNull);
    expect(openedProject(), isNull);
  });

  testWidgets("a launch arriving while the app is up opens one too",
      (tester) async {
    app = TestApp.create();
    await start(tester);
    await io(tester, app.openSomeChat);

    app.assistant.launch();
    await settleIo(tester);

    expect(openedChat(), isNull);
  });

  // Nothing is written by the gesture itself: it says where the chat will go,
  // and the screen it lands on makes one when the first thing is said.
  testWidgets("the next chat goes to the project the setting names",
      (tester) async {
    app = TestApp.create();
    await io(tester, () => app.repo.createProject("research"));
    await launchWith(tester, AppSettings(assistantProject: "research"));

    expect(openedProject(), "research");
    expect(await io(tester, () => app.store.list()), isEmpty);
  });

  testWidgets("a project that has since been deleted lands in the default one",
      (tester) async {
    app = TestApp.create();
    await launchWith(tester, AppSettings(assistantProject: "gone"));

    expect(openedProject(), isNull);
  });

  // Nothing is made here either: the page opens on no chat, and the first word
  // is what creates one.
  testWidgets("the voice view opens voice mode with nothing to speak into yet",
      (tester) async {
    app = TestApp.create(voiceModels: voiceModelIds);
    // Both models picked in the same write as the view: two writes would race,
    // since one goes through the notifier and the other straight to the file.
    await launchWith(
      tester,
      AppSettings(
        voiceRecognitionModelId: voiceModelPair.recognition,
        voiceSpeechModelId: voiceModelPair.speech,
        assistantView: AssistantView.voice,
      ),
      settle: false,
    );

    await pumpUntil(tester, find.byType(VoicePage));
    expect(find.byType(VoicePage), findsOneWidget);
    expect(openedChat(), isNull);
    // `runAsync` rather than `io`: the orb never comes to rest, so the settle
    // `io` starts with would time out on it.
    expect(await tester.runAsync(() => app.repo.listChats()), isEmpty);
  });

  testWidgets("the voice view with no models offers the settings instead",
      (tester) async {
    app = TestApp.create();
    await launchWith(tester, AppSettings(assistantView: AssistantView.voice));

    expect(find.byType(VoicePage), findsNothing);
    expect(find.text("Voice mode needs two models"), findsOneWidget);
  });

  testWidgets("the gesture makes a new chat rather than reopening one",
      (tester) async {
    app = TestApp.create();
    final old = await io(tester, () => app.seedChat());
    await start(tester);
    app.container.read(selectedChatIdProvider.notifier).select(old.state.id);

    app.assistant.launch();
    await settleIo(tester);

    expect(openedChat(), isNot(old.state.id));
  });
}
