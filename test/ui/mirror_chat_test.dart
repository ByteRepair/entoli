import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry;
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/selection.dart";

import "../harness.dart";

/// A chat whose home device is somewhere else: its writes go there, and what
/// is not offered is what only that device has — its files, its providers,
/// and anything at all while it is away.
void main() {
  const chatId = "remote-1";

  final state = ChatState(
    id: chatId,
    title: "On the desktop",
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
  );

  final chat = Chat(
    state: state,
    messages: [
      Message(
        id: "m1",
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [TextPart(text: "said at home")],
      ),
      Message(
        id: "r1",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [TextPart(text: "answered at home")],
      ),
    ],
  );

  TestApp appWith({
    required bool online,
    bool omada = false,
    bool running = false,
    List<ToolApproval> approvals = const [],
    List<AskRequest> questions = const [],
  }) => TestApp.create(
    remotes: [
      RemoteChatEntry(
        chatId: chatId,
        deviceId: "device-1",
        deviceName: "Desktop",
        state: state,
        online: online,
        omada: omada,
      ),
    ],
    mirrors: {
      chatId: ChatViewState(
        chat: chat,
        isRunning: running,
        approvals: {"r1": approvals},
        questions: {"r1": questions},
        status: online ? null : "offline — showing what this device last had",
      ),
    },
  );

  late TestApp app;
  tearDown(() => app.dispose());

  Future<void> openMirror(WidgetTester tester, {bool running = false}) async {
    app.container.read(selectedChatIdProvider.notifier).select(chatId);
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(MirrorStrip));
    // A running turn ends in a caret, which never comes to rest.
    if (!running) await settleIo(tester);
  }

  group("the page", () {
    // A paired device is the user's own: following its chat is all it takes
    // to type into it and change it.
    testWidgets("online it is a chat like a local one, a composer and edits", (
      tester,
    ) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.text("said at home"), findsOneWidget);
      expect(find.byType(Composer), findsOneWidget);
      expect(find.byType(ViewOnlyBar), findsNothing);
      expect(find.byTooltip("Edit"), findsWidgets);
      expect(find.byTooltip("Regenerate"), findsWidgets);
    });

    testWidgets("the strip under the title bar names the device, and the "
        "title does not", (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.text("On Desktop"), findsOneWidget);
      expect(find.text("Desktop"), findsNothing);
      // A row of its own, under the title bar: nothing it covers.
      expect(
        tester.getRect(find.byType(MirrorStrip)).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(Scrollable).first).top),
      );
    });

    testWidgets("the title bar opens the chat's settings, less what is the "
        "device's own", (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      await tester.tap(find.text("On the desktop"));
      await settleIo(tester);
      expect(find.byType(ChatSettingsPage), findsOneWidget);
      expect(find.text("On Desktop"), findsOneWidget);
      expect(find.text("Context"), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text("Delete chat"),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ChatSettingsPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text("Delete chat"), findsOneWidget);
      // Its files and its providers are the home device's.
      expect(find.text("Chat workspace"), findsNothing);
      expect(find.text("LLM"), findsNothing);
    });

    testWidgets("offline the settings are read, not written", (tester) async {
      app = appWith(online: false);
      await openMirror(tester);

      await tester.tap(find.text("On the desktop"));
      await settleIo(tester);
      final save = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.check),
      );
      expect(save.onPressed, isNull);
      expect(find.text("Delete chat"), findsNothing);
    });

    testWidgets("offline it is a snapshot: said twice, and nothing to type or "
        "change", (tester) async {
      app = appWith(online: false);
      await openMirror(tester);

      expect(find.text("Desktop is offline"), findsOneWidget);
      expect(
        find.text("Offline — showing what this device last had"),
        findsOneWidget,
      );
      expect(find.byType(Composer), findsNothing);
      expect(find.byTooltip("Edit"), findsNothing);
      // The point of keeping the snapshot: it is still readable.
      expect(find.text("answered at home"), findsOneWidget);
    });

    testWidgets("a command waiting to be allowed is drawn here", (
      tester,
    ) async {
      app = appWith(
        online: true,
        running: true,
        approvals: const [
          ToolApproval(id: "a1", toolName: "bash", argumentsText: "rm -rf /"),
        ],
      );
      await openMirror(tester, running: true);

      await pumpUntil(tester, find.textContaining("rm -rf /"));
      expect(find.textContaining("rm -rf /"), findsOneWidget);
    });

    testWidgets("a question takes the composer's place, as it does at home", (
      tester,
    ) async {
      app = appWith(
        online: true,
        running: true,
        questions: [
          const AskRequest(
            id: "q1",
            questions: [
              AskQuestion(
                question: "Which one?",
                options: [
                  AskOption(label: "This one"),
                  AskOption(label: "That one"),
                ],
              ),
            ],
          ),
        ],
      );
      await openMirror(tester, running: true);

      await pumpUntil(tester, find.text("Which one?"));
      expect(find.byType(Composer), findsNothing);
    });
  });

  group("the sidebar", () {
    /// The switcher, then the paired device's default project in it — which
    /// is the device's name alone, since its default project has no name.
    Future<void> pickRemote(WidgetTester tester) async {
      await app.pump(tester, const Sidebar());
      await settleIo(tester);
      await tester.tap(find.byIcon(Icons.unfold_more));
      await settleIo(tester);
      await tester.tap(find.text("Desktop").last);
      await settleIo(tester);
    }

    testWidgets("the paired device's project is offered in the switcher", (
      tester,
    ) async {
      app = appWith(online: true);
      await app.pump(tester, const Sidebar());
      await settleIo(tester);

      await tester.tap(find.byIcon(Icons.unfold_more));
      await settleIo(tester);

      // Its default project, so the device's name alone — the local default
      // has no name either.
      expect(find.text("Desktop"), findsOneWidget);
    });

    testWidgets("its name is styled by Omada on the device, not here", (
      tester,
    ) async {
      FontStyle? style() => tester
          .widget<Text>(
            find.descendant(
              of: find.byTooltip("Switch project"),
              matching: find.text("Desktop"),
            ),
          )
          .style
          ?.fontStyle;
      for (final omada in [true, false]) {
        app = appWith(online: true, omada: omada);
        await pickRemote(tester);
        expect(style() == FontStyle.italic, omada);
        app.dispose();
      }
      app = appWith(online: true);
    });

    testWidgets("picking it lists that device's chats", (tester) async {
      app = appWith(online: true);
      await pickRemote(tester);

      expect(find.text("On the desktop"), findsOneWidget);
    });

    testWidgets("a row says when the device is gone", (tester) async {
      app = appWith(online: false);
      await pickRemote(tester);

      expect(find.text("On the desktop"), findsOneWidget);
      expect(find.text("offline"), findsOneWidget);
    });

    testWidgets("a remote row's menu is a local one's, less the move", (
      tester,
    ) async {
      app = appWith(online: true);
      await pickRemote(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await settleIo(tester);
      for (final action in ["Pin", "Rename", "Delete"]) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      // Where to is a project on the home device.
      expect(find.text("Move to project…"), findsNothing);
    });

    testWidgets("an offline remote row has no menu", (tester) async {
      app = appWith(online: false);
      await pickRemote(tester);

      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets("tapping one selects it", (tester) async {
      app = appWith(online: true);
      await pickRemote(tester);

      await tester.tap(find.text("On the desktop"));
      await settleIo(tester);
      expect(app.container.read(selectedChatIdProvider), chatId);
    });
  });
}
