import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/shell/shell_voice.dart";
import "package:agent_chat/ui/voice/voice_page.dart";

import "../../harness.dart";
import "fake_native_shell.dart";
import "fake_native_transcript.dart" show settleShell;
import "package:agent_chat/ui/shell/shell_answers.dart";

/// Voice mode under the native shell: no page, a session that sends the
/// shell the voice, the transcript and the turn.
void main() {
  late TestApp app;
  late FakeNativeShell native;

  setUp(() {
    app = TestApp.create();
    native = FakeNativeShell.install();
  });
  tearDown(() => app.dispose());

  /// Voice mode over [chatId], opened as the shell's bridge opens it.
  Future<ShellVoiceSession> open(WidgetTester tester, String? chatId) async {
    late BuildContext context;
    await app.pump(
      tester,
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    late ShellVoiceSession session;
    session = ShellVoiceSession(
      app.container,
      chatId: chatId,
      meta: null,
      context: () => context,
      onDone: () => session.close(),
    );
    addTearDown(session.close);
    return session;
  }

  testWidgets("voice mode sends the chat's title, its lines and its turn, "
      "with no page behind it", (tester) async {
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
    await open(tester, chat.state.id);
    await settleShell(tester);

    expect(find.byType(VoicePage), findsNothing);
    final voice = native.lastVoice!;
    expect(voice.present, isTrue);
    expect(voice.title, "Walk");
    expect(voice.lines.map((l) => l.text), containsAll(["go on", "Half a"]));
    expect(native.lastTurn?.resume?.startedAt, isPositive);
    expect(app.container.read(shellAnswersProvider).turn.owner, isNotNull);
  });

  testWidgets("Done leaves voice mode", (tester) async {
    final session = await open(tester, null);
    await settleShell(tester);
    expect(native.lastVoice?.present, isTrue);

    session.done();
    await tester.pump();
    expect(native.lastVoice?.present, isFalse);
    expect(app.container.read(shellAnswersProvider).turn.owner, isNull);
  });
}
