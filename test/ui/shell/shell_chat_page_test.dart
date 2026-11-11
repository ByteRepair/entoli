import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:super_sliver_list/super_sliver_list.dart";

import "package:agent_chat/ui/app_chrome.dart" show appChromeProvider;
import "package:agent_chat/ui/shell/shell_app_chrome.dart";
import "package:agent_chat/ui/chat/chat_chrome.dart" show chatChromeProvider;
import "package:agent_chat/ui/shell/shell_chat_chrome.dart";
import "package:agent_chat/ui/shell/shell_page_bar.dart" show drawShellPageBar;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show defaultEmptyChatQuestion;
import "package:agent_chat/providers.dart" show appSettingsProvider;
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_new_chat.dart";
import "package:agent_chat/ui/shell/shell_answers.dart";
import "package:agent_chat/ui/shell/shell_window.dart";
import "package:agent_chat/app/frontend.dart";
import "package:agent_chat/ui/widgets/page_bar.dart";

import "../../harness.dart";
import "fake_native_shell.dart";

/// The chat page as the native shell hosts it: no Flutter bar or composer,
/// the toolbar and the composer sent as snapshots instead.
void main() {
  late TestApp app;
  late FakeNativeShell shell;

  setUp(() {
    app = TestApp.create();
    shell = FakeNativeShell.install();
  });
  tearDown(() => app.dispose());

  /// [composer] is how much of the bottom the shell's composer covers, which
  /// it reports as padding.
  Future<void> pump(WidgetTester tester, {double composer = 0}) => app.pump(
    tester,
    ProviderScope(
      overrides: [
        pageBarDrawProvider.overrideWithValue(drawShellPageBar),
        chatChromeProvider.overrideWithValue(const ShellChatChrome()),
        appChromeProvider.overrideWithValue(const ShellAppChrome()),
        frontendProvider.overrideWithValue(
          const FrontendChoice(current: Frontend.swiftUI, native: true),
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

  /// The shell composer on top, as the Swift reaches it.
  ComposerIntents composer() =>
      app.container.read(shellAnswersProvider).composer.owner!;

  /// A chat with something said in it, open: [said] messages, enough past
  /// the window's height to scroll.
  Future<void> openChat(
    WidgetTester tester, {
    bool finished = true,
    int said = 4,
  }) => io(tester, () async {
    final chat = await app.repo.createChat(title: "old chat");
    await app.writeChat(
      chat.copyWith(
        messages: [
          for (var i = 0; i < said; i++)
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
  });

  testWidgets("the new-chat screen goes to the shell, Flutter drawing none", (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(defaultEmptyChatQuestion), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(shell.lastNewChat?.present, isTrue);
    expect(shell.lastNewChat?.question, defaultEmptyChatQuestion);
    expect(shell.lastChatBar?.draft, isTrue);
    expect(shell.lastComposer?.present, isTrue);
  });

  testWidgets("a badge picks its project, and picked again the default", (
    tester,
  ) async {
    await pump(tester);
    final first = shell.lastNewChat!.projects.first;
    final screen = tester.state<ShellNewChatState>(find.byType(ShellNewChat));

    await screen.pick(null, first.project);
    await tester.pump();
    expect(app.container.read(selectedProjectProvider).project, first.project);
    expect(shell.lastNewChat!.selected!.project, first.project);

    await screen.pick(null, first.project);
    await tester.pump();
    expect(app.container.read(selectedProjectProvider).project, isNull);
  });

  // The row is off by default — Settings > General > Appearance > "Show
  // command chips in start page" — and the snapshot says which, so the Swift
  // draws no row rather than an empty one: an empty library says how to reach
  // the library, and a hidden row says nothing. A hidden row ships no list
  // either, since the Swift would only throw it away.
  testWidgets("the shell is told whether to draw the starter row", (
    tester,
  ) async {
    await pump(tester);
    expect(shell.lastNewChat?.showStarters, isFalse);
    expect(shell.lastNewChat?.starters, isEmpty);

    await io(
      tester,
      () => app.container
          .read(appSettingsProvider.notifier)
          .setShowCommandChips(true),
    );
    await tester.pump();

    expect(shell.lastNewChat?.showStarters, isTrue);
    expect(shell.lastNewChat?.starters, isNotEmpty);
  });

  testWidgets("a starter types its trigger into the composer", (tester) async {
    await pump(tester);
    final screen = tester.state<ShellNewChatState>(find.byType(ShellNewChat));
    screen.starter(ComposerTrigger.agent, "scout");
    await tester.pump();
    expect(shell.lastComposerValue?.text, "@scout ");
  });

  testWidgets("a chat fills the page, its title in the toolbar", (
    tester,
  ) async {
    await openChat(tester);
    await pump(tester);
    await settleIo(tester);
    expect(shell.lastChatBar?.title, "old chat");
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
    expect(shell.lastTurn?.resume?.startedAt, isPositive);
  });

  testWidgets("a finished chat sends an empty turn surface", (tester) async {
    await openChat(tester);
    await pump(tester);
    await settleIo(tester);
    expect(shell.lastTurn?.resume, isNull);
    expect(shell.lastTurn?.approvals, isEmpty);
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

  group("the keyboard", () {
    testWidgets("goes with a drag back through the conversation", (
      tester,
    ) async {
      await openChat(tester, said: 40);
      await pump(tester);
      await settleIo(tester);

      composer().focused(true);
      await tester.pump();
      expect(
        shell.sent["composerFocus"],
        isNull,
        reason: "the field said so; nothing goes back",
      );

      await tester.drag(find.byType(SuperListView), const Offset(0, 200));
      await tester.pump();
      expect(shell.sent["composerFocus"], [false]);
    });

    testWidgets("is not counted twice in the padding", (tester) async {
      addTearDown(() => shellInsets.value = EdgeInsets.zero);
      shellInsets.value = const EdgeInsets.only(top: 116, bottom: 384);
      late MediaQueryData seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 328)),
          child: ShellInsets(
            child: Builder(
              builder: (context) {
                seen = MediaQuery.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(seen.padding, const EdgeInsets.only(top: 116, bottom: 56));
      expect(seen.viewPadding, const EdgeInsets.only(top: 116, bottom: 384));
    });
  });

  testWidgets("sending goes back down to the latest", (tester) async {
    await openChat(tester, said: 40);
    await pump(tester);
    await settleIo(tester);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    await tester.drag(find.byType(SuperListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(position.maxScrollExtent));

    composer().edited("hello", 5, 5);
    composer().run(ComposerAction.send);
    await settleIo(tester);
    expect(position.pixels, position.maxScrollExtent);
  });

  group("an activity's drawer", () {
    /// A chat whose reply ran [commands], one call each, each answered.
    Future<void> openRuns(WidgetTester tester, List<String> commands) =>
        io(tester, () async {
          final chat = await app.repo.createChat(title: "runs");
          await app.writeChat(
            chat.copyWith(
              messages: [
                Message(
                  id: "m0",
                  role: MessageRole.user,
                  createdAt: DateTime(2026),
                  parts: const [TextPart(text: "go")],
                ),
                Message(
                  id: "m1",
                  role: MessageRole.assistant,
                  createdAt: DateTime(2026, 1, 1, 0, 1),
                  parts: [
                    for (final (i, command) in commands.indexed) ...[
                      MessagePart.toolCall(
                        toolCall: ToolCall(
                          id: "c$i",
                          name: "bash",
                          argumentsJson: '{"command":"$command"}',
                        ),
                      ),
                      MessagePart.toolResult(
                        result: ToolResult(
                          callId: "c$i",
                          returnCode: 0,
                          output: "out of $command",
                        ),
                      ),
                    ],
                    const TextPart(text: "done"),
                  ],
                ),
              ],
            ),
          );
          app.container
              .read(selectedChatIdProvider.notifier)
              .select(chat.state.id);
        });

    testWidgets("is a page the composer steps aside for, not a sheet under "
        "it", (tester) async {
      await openRuns(tester, ["ls"]);
      await pump(tester);
      await settleIo(tester);
      await tester.tap(find.text("Used tool: bash"));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      final output = find.text("out of ls");
      expect(output, findsOneWidget);
      // A page is what the window's chrome steps aside for.
      expect(ModalRoute.of(tester.element(output)), isA<PageRoute<void>>());
      // Its bar is the page's: the window's under the shell, which `main`
      // turns on above the Navigator rather than here around the page.
      final bar = tester.widget<PageBar>(find.byType(PageBar));
      expect(bar.title, "bash");

      // The window's back, which the shell sends as the bar's.
      Navigator.of(tester.element(output)).pop();
      await tester.pumpAndSettle();
      expect(find.text("out of ls"), findsNothing);
    });
  });
}
