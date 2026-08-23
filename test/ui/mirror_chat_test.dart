import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

/// The read-only half of the app: a chat whose home device is somewhere else.
/// Everything here is about what is *not* offered — the composer, the chat's
/// settings, the menu that would write to a disk this device does not have.
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

  TestApp appWith({required bool online}) => TestApp.create(
        remotes: [
          RemoteChatEntry(
            chatId: chatId,
            deviceId: "device-1",
            deviceName: "Desktop",
            state: state,
            online: online,
          ),
        ],
        mirrors: {
          chatId: ChatViewState(
            chat: chat,
            status: online ? null : "offline — showing what this device last had",
          ),
        },
      );

  late TestApp app;
  tearDown(() => app.dispose());

  Future<void> openMirror(WidgetTester tester) async {
    app.container.read(selectedChatIdProvider.notifier).select(chatId);
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(ViewOnlyBar));
    await settleIo(tester);
  }

  group("the page", () {
    testWidgets("shows the conversation with a view-only bar, not a composer",
        (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.text("said at home"), findsOneWidget);
      expect(find.text("answered at home"), findsOneWidget);
      expect(find.byType(ViewOnlyBar), findsOneWidget);
      expect(find.text("View only"), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
    });

    testWidgets("names the device that owns it", (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.text("Desktop"), findsOneWidget);
    });

    testWidgets("the title bar does not open the chat's settings",
        (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      await tester.tap(find.text("On the desktop"));
      await settleIo(tester);
      expect(find.byType(ChatSettingsPage), findsNothing);
    });

    testWidgets("offline it says so twice: over the chat and where the composer was",
        (tester) async {
      app = appWith(online: false);
      await openMirror(tester);

      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.text("Desktop is offline"), findsOneWidget);
      expect(find.text("Offline — showing what this device last had"),
          findsOneWidget);
      // The point of keeping the snapshot: it is still readable.
      expect(find.text("answered at home"), findsOneWidget);
    });

    testWidgets("online there is no banner", (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.byType(OfflineBanner), findsNothing);
    });
  });

  group("the sidebar", () {
    Future<void> openSidebar(WidgetTester tester) async {
      await app.pump(tester, const Sidebar());
      await settleIo(tester);
    }

    testWidgets("lists the chat under Remotes with its device", (tester) async {
      app = appWith(online: true);
      await openSidebar(tester);

      expect(find.text("Remotes"), findsOneWidget);
      expect(find.text("On the desktop"), findsOneWidget);
      expect(find.text("Desktop"), findsOneWidget);
    });

    testWidgets("says which device is gone rather than dropping the row",
        (tester) async {
      app = appWith(online: false);
      await openSidebar(tester);

      expect(find.text("On the desktop"), findsOneWidget);
      expect(find.text("Desktop — offline"), findsOneWidget);
    });

    testWidgets("a remote row carries none of a local chat's menu",
        (tester) async {
      app = appWith(online: true);
      await openSidebar(tester);

      await tester.longPress(find.text("On the desktop"));
      await settleIo(tester);
      for (final action in ["Pin", "Rename", "Move to", "Delete"]) {
        expect(find.text(action), findsNothing, reason: "$action on a mirror");
      }
    });

    testWidgets("tapping one selects it", (tester) async {
      app = appWith(online: true);
      await openSidebar(tester);

      await tester.tap(find.text("On the desktop"));
      await settleIo(tester);
      expect(app.container.read(selectedChatIdProvider), chatId);
    });
  });
}
