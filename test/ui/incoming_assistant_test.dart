import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/assistant_view.dart";
import "package:agent_chat/ui/assistant/incoming_assistant.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
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

  String? openedChat() => app.container.read(selectedChatIdProvider);
  String? openedProject() => app.container.read(selectedProjectProvider);

  testWidgets("nothing opens when the gesture never happened", (tester) async {
    app = TestApp.create();
    await start(tester);

    expect(openedChat(), isNull);
  });

  testWidgets("a launch waiting at startup opens a new chat", (tester) async {
    app = TestApp.create();
    app.assistant.pending = true;
    await start(tester);

    expect(openedChat(), isNotNull);
    expect(openedProject(), isNull);
  });

  testWidgets("a launch arriving while the app is up opens one too",
      (tester) async {
    app = TestApp.create();
    await start(tester);
    expect(openedChat(), isNull);

    app.assistant.launch();
    await settleIo(tester);

    expect(openedChat(), isNotNull);
  });

  testWidgets("the chat lands in the project the setting names", (tester) async {
    app = TestApp.create();
    await io(tester, () async {
      await app.repo.createProject("research");
      await app.seedSettings(AppSettings(assistantProject: "research"));
    });
    app.assistant.pending = true;
    await start(tester);

    expect(openedProject(), "research");
    final chats = await io(tester, () => app.store.list());
    expect(chats.map((c) => c.project), everyElement("research"));
  });

  testWidgets("a project that has since been deleted lands in the default one",
      (tester) async {
    app = TestApp.create();
    await io(tester, () => app.seedSettings(AppSettings(assistantProject: "gone")));
    app.assistant.pending = true;
    await start(tester);

    expect(openedProject(), isNull);
    expect(openedChat(), isNotNull);
  });

  testWidgets("the voice view opens voice mode over the new chat",
      (tester) async {
    app = TestApp.create(voiceModels: voiceModelIds);
    // Both models picked in the same write as the view: two writes would race,
    // since one goes through the notifier and the other straight to the file.
    await io(tester, () => app.seedSettings(AppSettings(
          voiceRecognitionModelId: voiceModelPair.recognition,
          voiceSpeechModelId: voiceModelPair.speech,
          assistantView: AssistantView.voice,
        )));
    app.assistant.pending = true;
    await start(tester, settle: false);

    await pumpUntil(tester, find.byType(VoicePage));
    expect(find.byType(VoicePage), findsOneWidget);
    expect(openedChat(), isNotNull);
  });

  testWidgets("the voice view with no models offers the settings instead",
      (tester) async {
    app = TestApp.create();
    await io(tester,
        () => app.seedSettings(AppSettings(assistantView: AssistantView.voice)));
    app.assistant.pending = true;
    await start(tester);

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
