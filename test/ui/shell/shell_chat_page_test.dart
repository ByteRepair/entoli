import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/project.dart" show defaultEmptyChatQuestion;
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/widgets/liquid_glass.dart";

import "../../harness.dart";

/// The chat page as the native shell hosts it: no Flutter bar or composer,
/// the toolbar and the composer sent as snapshots instead.
void main() {
  late TestApp app;
  late Map<String, Map<String, Object?>> sent;

  setUp(() {
    app = TestApp.create();
    sent = {};
  });
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) => app.pump(
    tester,
    ProviderScope(
      overrides: [
        liquidGlassProvider.overrideWithValue(
          const LiquidGlass(available: true, on: true, shell: true),
        ),
        shellOutboxProvider.overrideWithValue(
          ShellOutbox((concern, map) => sent[concern] = map),
        ),
      ],
      child: const ChatPage(),
    ),
  );

  testWidgets("the new-chat screen fills the page", (tester) async {
    await pump(tester);
    final question = find.text(defaultEmptyChatQuestion);
    expect(question, findsOneWidget);
    expect(tester.getSize(question).height, greaterThan(0));
    expect(find.byType(AppBar), findsNothing);
    expect(sent["chatBar"]?["title"], "New Chat");
    expect(sent["composer"]?["present"], isTrue);
  });

  testWidgets("a chat fills the page, its title in the toolbar", (
    tester,
  ) async {
    final chat = await io(tester, () => app.seedChat(title: "old chat"));
    app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
    await pump(tester);
    await settleIo(tester);
    expect(sent["chatBar"]?["title"], "old chat");
    final reply = find.byType(Scrollable).first;
    expect(tester.getSize(reply).height, greaterThan(0));
  });
}
