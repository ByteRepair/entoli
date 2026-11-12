import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:super_sliver_list/super_sliver_list.dart";

import "package:agent_chat/ui/app_chrome.dart" show appChromeProvider;
import "package:agent_chat/ui/shell/shell_app_chrome.dart";
import "package:agent_chat/ui/chat/chat_chrome.dart" show chatChromeProvider;
import "package:agent_chat/ui/shell/shell_chat_chrome.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show defaultEmptyChatQuestion;
import "package:agent_chat/providers.dart" show appSettingsProvider;
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_new_chat.dart";
import "package:agent_chat/ui/shell/shell_answers.dart";
import "package:agent_chat/app/frontend.dart";

import "../../harness.dart";
import "fake_native_shell.dart";
import "fake_native_transcript.dart";

/// The chat page as the native shell hosts it: no Flutter bar or composer,
/// the toolbar and the composer sent as snapshots instead.
void main() {
  late TestApp app;
  late FakeNativeShell shell;
  late FakeNativeTranscript transcript;

  setUp(() {
    app = TestApp.create();
    shell = FakeNativeShell.install();
    transcript = FakeNativeTranscript.install();
  });
  tearDown(() => app.dispose());

  /// [composer] is how much of the bottom the shell's composer covers, which
  /// it reports as padding.
  Future<void> pump(WidgetTester tester, {double composer = 0}) => app.pump(
    tester,
    ProviderScope(
      overrides: [
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
          child: const ShellChatHost(child: ChatPage()),
        ),
      ),
    ),
  );

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
    final screen =
        app.container.read(shellAnswersProvider).newChat.owner!
            as NewChatRunner;

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
    final screen =
        app.container.read(shellAnswersProvider).newChat.owner!
            as NewChatRunner;
    screen.starter(ComposerTrigger.agent, "scout");
    await tester.pump();
    expect(shell.lastComposerValue?.text, "@scout ");
  });

  testWidgets("a chat's conversation goes to the shell, Flutter drawing no "
      "list, its title in the toolbar", (tester) async {
    await openChat(tester);
    await pump(tester);
    await settleShell(tester);
    expect(shell.lastChatBar?.title, "old chat");
    expect(find.byType(SuperListView), findsNothing);
    expect(transcript.conversations.last.order, [
      for (var i = 0; i < 4; i++) "message:m$i",
    ]);
  });

  testWidgets("an interrupted turn's offer to carry on goes to the shell", (
    tester,
  ) async {
    await openChat(tester, finished: false);
    await pump(tester);
    await settleShell(tester);
    expect(shell.lastTurn?.resume?.startedAt, isPositive);
  });

  testWidgets("a finished chat sends an empty turn surface", (tester) async {
    await openChat(tester);
    await pump(tester);
    await settleShell(tester);
    expect(shell.lastTurn?.resume, isNull);
    expect(shell.lastTurn?.approvals, isEmpty);
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

    testWidgets("is the shell's detail, sent when its node is opened", (
      tester,
    ) async {
      await openRuns(tester, ["ls"]);
      await pump(tester);
      await settleShell(tester);
      final node =
          transcript.rows["message:m1"]!.message!.blocks.first.nodes.single;
      expect(node.text, "Used tool: bash");

      app.container.read(shellAnswersProvider).transcript.owner!.open(node.id);
      await tester.pump();
      final detail = transcript.details.last;
      expect(detail.present, isTrue);
      expect(detail.title, "bash");
      expect(detail.sections.map((s) => s.body), contains("out of ls"));
      expect(find.byType(BottomSheet), findsNothing);
    });
  });
}
