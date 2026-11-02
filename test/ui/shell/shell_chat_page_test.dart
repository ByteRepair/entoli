import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:super_sliver_list/super_sliver_list.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show defaultEmptyChatQuestion;
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_new_chat.dart";
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

  /// [composer] is how much of the bottom the shell's composer covers, which
  /// it reports as padding.
  Future<void> pump(WidgetTester tester, {double composer = 0}) => app.pump(
    tester,
    ProviderScope(
      overrides: [
        liquidGlassProvider.overrideWithValue(
          const LiquidGlass(available: true, on: true),
        ),
        shellOutboxProvider.overrideWithValue(
          ShellOutbox((concern, map) => sent[concern] = map),
        ),
      ],
      child: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: EdgeInsets.only(bottom: composer)),
          child: const ChatPage(),
        ),
      ),
    ),
  );

  /// A chat with something said in it, open.
  Future<void> openChat(WidgetTester tester, {bool finished = true}) => io(
    tester,
    () async {
      final chat = await app.repo.createChat(title: "old chat");
      await app.writeChat(
        chat.copyWith(
          messages: [
            for (var i = 0; i < 4; i++)
              Message(
                id: "m$i",
                role: i.isEven ? MessageRole.user : MessageRole.assistant,
                createdAt: DateTime(2026, 1, 1, 0, i),
                parts: [TextPart(text: "line $i")],
              ),
          ],
        ),
        finished: finished,
      );
      app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
    },
  );

  testWidgets("the new-chat screen goes to the shell, Flutter drawing none", (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(defaultEmptyChatQuestion), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(sent["newChat"]?["present"], isTrue);
    expect(sent["newChat"]?["question"], defaultEmptyChatQuestion);
    expect(sent["chatBar"]?["title"], "New Chat");
    expect(sent["composer"]?["present"], isTrue);
  });

  testWidgets("a badge picks its project, and picked again the default", (
    tester,
  ) async {
    await pump(tester);
    final badges = sent["newChat"]!["projects"]! as List;
    final first = badges.first as Map;
    final screen = tester.state<ShellNewChatState>(find.byType(ShellNewChat));

    screen.handle("pick", {"device": null, "project": first["project"]});
    await tester.pump();
    expect(
      app.container.read(selectedProjectProvider).project,
      first["project"],
    );
    expect((sent["newChat"]!["selected"]! as Map)["project"], first["project"]);

    screen.handle("pick", {"device": null, "project": first["project"]});
    await tester.pump();
    expect(app.container.read(selectedProjectProvider).project, isNull);
  });

  testWidgets("a starter types its trigger into the composer", (tester) async {
    await pump(tester);
    final screen = tester.state<ShellNewChatState>(find.byType(ShellNewChat));
    screen.handle("starter", {"trigger": "@", "name": "scout"});
    await tester.pump();
    expect(sent["composerValue"]?["text"], "@scout ");
  });

  testWidgets("a chat fills the page, its title in the toolbar", (
    tester,
  ) async {
    await openChat(tester);
    await pump(tester);
    await settleIo(tester);
    expect(sent["chatBar"]?["title"], "old chat");
    expect(tester.getSize(find.byType(SuperListView)).height, 600);
  });

  testWidgets("the conversation runs under the composer, padded to clear it", (
    tester,
  ) async {
    await openChat(tester);
    await pump(tester, composer: 80);
    await settleIo(tester);
    final list = find.byType(SuperListView);
    expect(tester.getRect(list).bottom, 600, reason: "under the composer");
    final padding = MediaQuery.paddingOf(tester.element(list)).bottom;
    expect(padding, greaterThanOrEqualTo(80), reason: "its end clears it");
  });

  testWidgets("an interrupted turn's offer to carry on goes to the shell", (
    tester,
  ) async {
    await openChat(tester, finished: false);
    await pump(tester);
    await settleIo(tester);
    expect(sent["turn"]?["resume"], startsWith("Unfinished turn"));
  });

  testWidgets("a finished chat sends an empty turn surface", (tester) async {
    await openChat(tester);
    await pump(tester);
    await settleIo(tester);
    expect(sent["turn"]?["resume"], isNull);
    expect(sent["turn"]?["approvals"], isEmpty);
  });

  testWidgets("a tooltip on the page opens above what it is about", (
    tester,
  ) async {
    await openChat(tester);
    await pump(tester, composer: 80);
    await settleIo(tester);
    final list = tester.element(find.byType(SuperListView));
    expect(TooltipTheme.of(list).preferBelow, isFalse);
  });
}
