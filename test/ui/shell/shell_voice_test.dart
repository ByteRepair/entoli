import "package:entoli_glass/entoli_glass.dart" show VoicePhase;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_page_bar.dart" show drawShellPageBar;
import "package:agent_chat/ui/widgets/page_bar.dart" show pageBarDrawProvider;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/shell/shell_voice.dart";
import "package:agent_chat/app/voice_controller.dart";
import "package:agent_chat/ui/voice/voice_page.dart";
import "package:agent_chat/app/frontend.dart";

import "../../harness.dart";
import "fake_native_shell.dart";

/// Voice mode under the native shell: the page draws nothing of its own and
/// sends the shell the session, the transcript and the turn.
void main() {
  late TestApp app;
  late FakeNativeShell native;

  setUp(() {
    app = TestApp.create();
    native = FakeNativeShell.install();
  });
  tearDown(() => app.dispose());

  Widget shell(Widget child) => ProviderScope(
    overrides: [
      pageBarDrawProvider.overrideWithValue(drawShellPageBar),
      frontendProvider.overrideWithValue(
        const FrontendChoice(current: Frontend.swiftUI, native: true),
      ),
    ],
    child: child,
  );

  testWidgets("the page sends the chat's title, its lines and its turn", (
    tester,
  ) async {
    final chat = await io(tester, () async {
      final made = await app.repo.createChat(title: "Walk");
      final full = made.copyWith(
        messages: [
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
        ],
      );
      await app.writeChat(full, finished: false);
      return full;
    });
    await app.pump(
      tester,
      shell(VoicePage(chatId: chat.state.id)),
      settle: false,
    );
    for (var i = 0; i < 20 && native.lastTurn?.resume == null; i++) {
      await io(tester, () async {});
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(Scaffold), findsNothing, reason: "the shell draws it");
    final voice = native.lastVoice!;
    expect(voice.present, isTrue);
    expect(voice.title, "Walk");
    expect(voice.lines.map((l) => l.text), containsAll(["go on", "Half a"]));
    expect(native.lastTurn?.resume, startsWith("Unfinished turn"));
  });

  testWidgets("the microphone's level goes as it moves", (tester) async {
    final level = ValueNotifier(0.0);
    addTearDown(level.dispose);
    await app.pump(
      tester,
      shell(
        Consumer(
          builder: (context, ref, _) => ShellVoice(
            voice: VoiceViewState(status: VoiceStatus.listening, level: level),
            controller: ref.read(voiceControllerProvider(null).notifier),
            onDone: () {},
          ),
        ),
      ),
      settle: false,
    );
    expect(native.lastVoice?.status, VoicePhase.listening);

    level.value = 0.5;
    level.value = 0.9;
    expect(native.levels, [0.5, 0.9]);
  });
}
