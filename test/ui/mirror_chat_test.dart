import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/sync_hub.dart" show RemoteChatEntry;
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/chat/mirror_controller.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../fakes.dart";
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

  TestApp appWith({
    required bool online,
    bool omada = false,
    MirrorControl control = const MirrorControl(),
    bool running = false,
    List<ToolApproval> approvals = const [],
    List<AskRequest> questions = const [],
  }) =>
      TestApp.create(
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
        control: control,
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

      expect(find.byType(MirrorStrip), findsOneWidget);
      expect(find.text("Desktop is offline"), findsOneWidget);
      expect(find.text("Offline — showing what this device last had"),
          findsOneWidget);
      // The point of keeping the snapshot: it is still readable.
      expect(find.text("answered at home"), findsOneWidget);
    });

    testWidgets("online there is no banner", (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      expect(find.byType(MirrorStrip), findsNothing);
    });
  });

  group("taking control", () {
    /// Held control is what puts a composer on the page. The lock itself is
    /// the home device's answer and is proven over the wire in
    /// `sync_hub_pair_test.dart`; here it is only what gets drawn.
    testWidgets("the bar offers it, and asking is what the button does",
        (tester) async {
      app = appWith(online: true);
      await openMirror(tester);

      await tester.tap(find.text("Take control"));
      await settleIo(tester);

      final control = app.container
          .read(mirrorControlProvider(chatId).notifier) as FakeMirrorControl;
      expect(control.taken, [chatId]);
    });

    testWidgets("while asking, the button is dead and the bar says so",
        (tester) async {
      app = appWith(online: true, control: const MirrorControl(asking: true));
      await openMirror(tester);

      expect(find.text("Asking to take control…"), findsOneWidget);
      expect(enabled(tester, find.widgetWithText(TextButton, "Take control")),
          isFalse);
    });

    testWidgets("another device holding it leaves nothing to press",
        (tester) async {
      app = appWith(online: true, control: const MirrorControl(holder: "d2"));
      await openMirror(tester);

      expect(find.text("Another device is driving this chat"), findsOneWidget);
      expect(find.text("Take control"), findsNothing);
    });

    testWidgets("offline there is nothing to take", (tester) async {
      app = appWith(online: false);
      await openMirror(tester);

      expect(find.text("Take control"), findsNothing);
    });
  });

  group("holding control", () {
    final held = MirrorControl(holder: "device-me", held: true);

    Future<void> openHeld(WidgetTester tester, {
      bool running = false,
      List<ToolApproval> approvals = const [],
      List<AskRequest> questions = const [],
    }) async {
      app = appWith(
        online: true,
        control: held,
        running: running,
        approvals: approvals,
        questions: questions,
      );
      app.container.read(selectedChatIdProvider.notifier).select(chatId);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(MirrorStrip));
      // A running turn ends in a caret, which never comes to rest.
      if (!running) await settleIo(tester);
    }

    testWidgets("the composer takes the view-only bar's place", (tester) async {
      await openHeld(tester);

      expect(find.byType(Composer), findsOneWidget);
      expect(find.byType(ViewOnlyBar), findsNothing);
    });

    testWidgets("the page says the work is happening elsewhere",
        (tester) async {
      await openHeld(tester);

      expect(find.text("Running on Desktop"), findsOneWidget);
    });

    testWidgets("handing it back is offered", (tester) async {
      await openHeld(tester);

      await tester.tap(find.text("Hand back"));
      await settleIo(tester);

      final control = app.container
          .read(mirrorControlProvider(chatId).notifier) as FakeMirrorControl;
      expect(control.released, [chatId]);
    });

    testWidgets("a command waiting to be allowed is drawn here", (tester) async {
      await openHeld(tester, running: true, approvals: const [
        ToolApproval(id: "a1", toolName: "bash", argumentsText: "rm -rf /"),
      ]);

      await pumpUntil(tester, find.textContaining("rm -rf /"));
      expect(find.textContaining("rm -rf /"), findsOneWidget);
    });

    testWidgets("a question takes the composer's place, as it does at home",
        (tester) async {
      await openHeld(tester, running: true, questions: [
        const AskRequest(id: "q1", questions: [
          AskQuestion(question: "Which one?", options: [
            AskOption(label: "This one"),
            AskOption(label: "That one"),
          ]),
        ]),
      ]);

      await pumpUntil(tester, find.text("Which one?"));
      expect(find.byType(Composer), findsNothing);
    });
  });

  /// The other end of the same lock. A chat of this device being typed into
  /// from a paired one is an ordinary local chat — same controller, same
  /// composer — with one line saying where the prompts are coming from.
  group("the home device", () {
    testWidgets("names the paired device driving one of its chats",
        (tester) async {
      const localId = "local-1";
      app = TestApp.create(drivenBy: const {localId: "Phone"});
      await io(
          tester,
          () => writeChatTo(
              app.store,
              Chat(
                state: ChatState(
                  id: localId,
                  title: "Mine",
                  createdAt: DateTime.utc(2026, 1, 1),
                  updatedAt: DateTime.utc(2026, 1, 1),
                ),
                messages: const [],
              )));
      app.container.read(selectedChatIdProvider.notifier).select(localId);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);

      expect(find.text("Driven from Phone"), findsOneWidget);
    });

    testWidgets("says nothing where nobody else is", (tester) async {
      app = TestApp.create();
      final chat = await io(tester, () => app.seedChat(title: "Mine"));
      app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);

      expect(find.textContaining("Driven from"), findsNothing);
    });
  });

  group("the sidebar", () {
    /// The switcher, then the paired device's default project in it — which
    /// is the device's name alone, since its default project has no name.
    Future<void> pickRemote(WidgetTester tester) async {
      await app.pump(tester, const Sidebar());
      await settleIo(tester);
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await settleIo(tester);
      await tester.tap(find.text("Desktop").last);
      await settleIo(tester);
    }

    testWidgets("the paired device's project is offered in the switcher",
        (tester) async {
      app = appWith(online: true);
      await app.pump(tester, const Sidebar());
      await settleIo(tester);

      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await settleIo(tester);

      // Its default project, so the device's name alone — the local default
      // has no name either.
      expect(find.text("Desktop"), findsOneWidget);
    });

    testWidgets("its name is styled by Omada on the device, not here",
        (tester) async {
      FontStyle? style() => tester
          .widget<Text>(find.descendant(
              of: find.byType(TextButton), matching: find.text("Desktop")))
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

    testWidgets("a remote row carries none of a local chat's menu",
        (tester) async {
      app = appWith(online: true);
      await pickRemote(tester);

      await tester.longPress(find.text("On the desktop"));
      await settleIo(tester);
      for (final action in ["Pin", "Rename", "Move to", "Delete"]) {
        expect(find.text(action), findsNothing, reason: "$action on a mirror");
      }
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
