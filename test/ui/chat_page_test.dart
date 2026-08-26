import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/theme.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// What is in the composer. The text rather than a finder over it: a
  /// `find.text` would match the same words drawn anywhere else on the page.
  String typed(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> open(WidgetTester tester, String chatId) async {
    app.container.read(selectedChatIdProvider.notifier).select(chatId);
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(Composer));
    await settleIo(tester);
  }

  /// A conversation taller than the window, so there is somewhere to scroll.
  Future<Chat> seedLongChat(
    WidgetTester tester, {
    String title = "at home",
    String? project,
    int messages = 40,
    bool finished = true,
  }) =>
      io(tester, () async {
        final chat = await app.repo.createChat(title: title, project: project);
        final said = [
          for (var i = 0; i < messages; i++)
            Message(
              id: "m$i",
              role: i.isEven ? MessageRole.user : MessageRole.assistant,
              createdAt: DateTime(2026, 1, 1, 0, i),
              parts: [TextPart(text: "line $i")],
            ),
        ];
        final full = chat.copyWith(messages: said);
        await app.writeChat(full, finished: finished);
        return full;
      });

  group("with nothing selected", () {
    // Nothing selected is the new-chat screen, and it is only a screen: no
    // chat is made until something is said.
    Future<void> openEmpty(WidgetTester tester) async {
      await app.pump(tester, const ChatPage(withDrawer: true), settle: false);
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);
    }

    Future<List<ChatState>> stored(WidgetTester tester) =>
        io(tester, () => app.repo.listChats());

    testWidgets("there is somewhere to type, and no chat behind it",
        (tester) async {
      await openEmpty(tester);

      expect(find.byType(Composer), findsOneWidget);
      expect(find.text("What would you like to discuss?"), findsOneWidget);
      expect(app.container.read(selectedChatIdProvider), isNull);
      expect(await stored(tester), isEmpty);
    });

    // The whole of the design: a screen nobody typed into leaves nothing on
    // disk, so there is no draft to hold and nothing to sweep up.
    testWidgets("leaving without typing writes nothing", (tester) async {
      await openEmpty(tester);
      await app.pump(tester, const SizedBox.shrink());

      expect(await stored(tester), isEmpty);
    });

    testWidgets("saying something makes the chat and puts it in it",
        (tester) async {
      await openEmpty(tester);

      await sendMessage(tester, "hello");

      final chats = await stored(tester);
      expect(chats, hasLength(1));
      expect(app.container.read(selectedChatIdProvider), chats.single.id);
      expect(find.text("hello"), findsOneWidget);
    });

    // The bar's own, wherever the sidebar is out of sight — there is no
    // button for it on the page any more.
    testWidgets("an old chat is opened through the drawer", (tester) async {
      await io(tester, () => app.seedChat(title: "old chat"));
      await openEmpty(tester);

      await tester.tap(find.byIcon(Icons.menu));
      await settleIo(tester);

      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.text("old chat"), findsOneWidget);
    });

    // A paired device's list is the one place nothing selected is not a new
    // chat: making one is this device's and would take the sidebar home.
    testWidgets("reading a paired device makes no chat", (tester) async {
      app.container
          .read(selectedRemoteProvider.notifier)
          .select((deviceId: "phone", project: null));

      await app.pump(tester, const ChatPage(withDrawer: true));

      expect(find.text("Pick a chat to follow."), findsOneWidget);
      expect(app.container.read(selectedChatIdProvider), isNull);
    });

    Future<void> openWithProject(WidgetTester tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await openEmpty(tester);
    }

    Future<void> pick(WidgetTester tester, String project) async {
      await tester.tap(find.widgetWithText(ChoiceChip, project));
      await settleIo(tester);
    }

    bool selectedOf(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

    /// Where the chat this screen made ended up. There is only ever one.
    Future<String?> projectOfMade(WidgetTester tester) async =>
        (await stored(tester)).single.project;

    // The default project has no badge: it is nothing selected.
    testWidgets("the named projects are badges", (tester) async {
      await openWithProject(tester);

      expect(find.widgetWithText(ChoiceChip, "work"), findsOneWidget);
      expect(find.text(defaultProjectLabel), findsNothing);
      expect(selectedOf(tester, "work"), isFalse);
    });

    // The built-in projects are always on offer, so the row is never empty:
    // with no project of the user's it is the built-ins alone.
    testWidgets("the built-ins are badges with no project of the user's",
        (tester) async {
      await openEmpty(tester);

      expect(find.widgetWithText(ChoiceChip, "Anonymous"), findsOneWidget);
      expect(find.byType(ChoiceChip), findsOneWidget);
    });

    testWidgets("picking the built-in badge moves the chat to it", (tester) async {
      await openEmpty(tester);

      await pick(tester, "Anonymous");

      expect(app.container.read(selectedProjectProvider), "anonymous");

      await sendMessage(tester, "hello");

      expect(await projectOfMade(tester), "anonymous");
    });

    // The badge says where the next chat goes, which is all it can say: there
    // is no chat yet for it to be about.
    testWidgets("picking one highlights it, and the chat lands there",
        (tester) async {
      await openWithProject(tester);

      await pick(tester, "work");

      expect(selectedOf(tester, "work"), isTrue);
      expect(app.container.read(selectedProjectProvider), "work");

      await sendMessage(tester, "hello");

      expect(await projectOfMade(tester), "work");
    });

    // Nothing selected is the default project, so leaving one is pressing it
    // again rather than finding a badge that stands for the way back.
    testWidgets("pressing the picked one again goes back to the default",
        (tester) async {
      await openWithProject(tester);

      await pick(tester, "work");
      await pick(tester, "work");

      expect(selectedOf(tester, "work"), isFalse);
      expect(app.container.read(selectedProjectProvider), isNull);

      await sendMessage(tester, "hello");

      expect(await projectOfMade(tester), isNull);
    });

    testWidgets("the chat lands in the default until a badge is picked",
        (tester) async {
      await openWithProject(tester);

      await sendMessage(tester, "hello");

      expect(await projectOfMade(tester), isNull);
    });

    // The settings are the screen's until there is a chat to write them on,
    // which is what the `meta` handed to `createChat` is for.
    group("settings picked before there is a chat", () {
      Future<void> pickNeverAsk(WidgetTester tester) async {
        await tester.tap(find.byTooltip("Chat settings"));
        await settleIo(tester);
        await scrollTo(tester, find.byType(DropdownButtonFormField<ApproveMode?>));
        await tester.tap(find.byType(DropdownButtonFormField<ApproveMode?>));
        await settleIo(tester);
        await tester.tap(find.textContaining("Run without asking").last);
        await settleIo(tester);
      }

      testWidgets("land on the chat the first message makes", (tester) async {
        await openEmpty(tester);
        await pickNeverAsk(tester);
        await tester.tap(find.byTooltip("Save"));
        await settleIo(tester);

        await sendMessage(tester, "hello");

        final made = (await stored(tester)).single;
        expect(await io(tester, () => app.savedMeta(made.id)),
            isA<ChatMeta>().having((m) => m.approveMode, "approveMode", ApproveMode.never));
      });

      // Backed out of rather than saved, so the screen goes on holding what it
      // had — which is nothing, and nothing is what the chat inherits.
      testWidgets("a page dismissed without saving changes nothing",
          (tester) async {
        await openEmpty(tester);
        await pickNeverAsk(tester);
        await tester.pageBack();
        await settleIo(tester);

        await sendMessage(tester, "hello");

        final made = (await stored(tester)).single;
        expect((await io(tester, () => app.savedMeta(made.id))).approveMode, isNull);
      });
    });

    // The bug that started this: switching project used to drop the selection,
    // which remounted the pane and took the composer's contents with it. There
    // is nothing to remount now — the screen is not keyed on a chat.
    testWidgets("picking one keeps what was typed", (tester) async {
      await openWithProject(tester);
      await tester.enterText(find.byType(TextField), "in which project?");

      await pick(tester, "work");

      expect(typed(tester), "in which project?");
    });

    testWidgets("the drawer shows the picked project's chats", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await io(tester, () => app.seedChat(title: "at work", project: "work"));
      await io(tester, () => app.seedChat(title: "at home"));
      await openEmpty(tester);

      await pick(tester, "work");
      await tester.tap(find.byIcon(Icons.menu));
      await settleIo(tester);

      expect(find.text("at work"), findsOneWidget);
      expect(find.text("at home"), findsNothing);
    });
  });

  ScrollPosition position(WidgetTester tester) =>
      tester.widget<Scrollable>(find.byType(Scrollable).first).controller!.position;

  testWidgets("a chat opens at its latest message", (tester) async {
    final chat = await seedLongChat(tester);

    await open(tester, chat.state.id);

    expect(position(tester).pixels, position(tester).maxScrollExtent);
    expect(find.text("line 39"), findsOneWidget);
    expect(find.text("line 0"), findsNothing);
  });

  testWidgets("the bar names the chat wherever the list is scrolled to",
      (tester) async {
    final chat = await seedLongChat(tester, title: "at work", project: "work");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at work")),
        findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text("work")),
        findsOneWidget);
    expect(find.text(appTitle), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at work")),
        findsOneWidget);
    expect(find.text(appTitle), findsNothing);
  });

  // Every chat is in one, so naming the default on all of them says nothing.
  testWidgets("a chat in the default project is titled and nothing more",
      (tester) async {
    final chat = await seedLongChat(tester, title: "at home");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at home")),
        findsOneWidget);
    expect(find.text("Default"), findsNothing);
  });

  // A built-in project's directory name is not what the bar should read; it is
  // labelled the way the menus label it.
  testWidgets("a chat in a built-in project is named by the project's label",
      (tester) async {
    final chat =
        await seedLongChat(tester, title: "off the record", project: "anonymous");

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("Anonymous")),
        findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text("anonymous")),
        findsNothing);
  });

  // The case the scroll-position bar got wrong: nothing to scroll used to mean
  // the app's name over every chat short enough to fit.
  testWidgets("a chat with nothing to scroll is named too", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "brand new"));

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("brand new")),
        findsOneWidget);
    expect(find.text(appTitle), findsNothing);
  });

  /// The countdown is drawn, and the bar grew for it. The lines are laid out
  /// inside the bar, so one too short to hold them overflows and fails the test
  /// before either of these reads anything.
  void expectCountdownFits(WidgetTester tester) {
    final bar = find.byType(AppBar);
    expect(find.descendant(of: bar, matching: find.byIcon(Icons.hourglass_empty)),
        findsOneWidget);
    expect(tester.getSize(bar).height, greaterThan(kToolbarHeight));
  }

  // Three lines — a title, a project and a countdown — do not fit the 56dp bar
  // every other chat gets, and the last of them was being clipped.
  testWidgets("a chat that is both in a project and temporary fits its bar",
      (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "at work", project: "work"));
    await io(tester, () => app.makeTemporary(chat.state));

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("work")),
        findsOneWidget);
    expectCountdownFits(tester);
  });

  // A phone set to a large font, which is where this was found: two lines fit
  // the 56dp toolbar at the default text size and not much past it, so the bar
  // used to clip the countdown rather than grow for it.
  for (final scale in [1.3, 2.0]) {
    testWidgets("a temporary chat fits its bar at text scale $scale",
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final chat = await io(tester, () => app.seedChat(title: "at home"));
      await io(tester, () => app.makeTemporary(chat.state));

      await open(tester, chat.state.id);

      expectCountdownFits(tester);
    });
  }

  // A pinned chat shows a pin in the title bar where a temporary chat's
  // hourglass would go. Pinning clears the TTL anchor, so the two never both
  // appear — and a pin is plain text, so no timer is needed to keep it current.
  testWidgets("a pinned chat shows a pin in the title bar", (tester) async {
    final chat = await seedLongChat(tester, title: "kept");
    await io(tester, () => app.repo.pinChat(chat.state.id, chat.state));

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("Pinned")),
        findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_empty), findsNothing);
  });

  group("a chat with nothing said in it", () {
    Future<void> openBlank(WidgetTester tester) async {
      final chat = await io(tester, () => app.seedChat(title: "brand new"));
      await open(tester, chat.state.id);
    }

    // The composer's menus are the only place these are named, and nothing
    // names them until the character that opens one has been typed.
    testWidgets("offers what the / and @ menus hold", (tester) async {
      await openBlank(tester);

      expect(find.text("/review"), findsOneWidget);
      expect(find.text("@explore"), findsOneWidget);
    });

    testWidgets("picking one types it, and does not reach for the keyboard",
        (tester) async {
      await openBlank(tester);

      await tester.tap(find.text("/review"));
      await tester.pump();

      expect(typed(tester), "/review ");
      expect(holdsCaret(tester, find.byType(TextField)), isFalse);
    });

    // Appended wherever the caret was, a `/command` is text nothing expands:
    // `prompt_library.dart`'s `_command` only reads one at the start of the message,
    // and the composer's own menu gates `/` on the same rule.
    testWidgets("a command lands where a command is read from", (tester) async {
      await openBlank(tester);
      await tester.enterText(find.byType(TextField), "about the parser");
      await tester.pump();

      await tester.tap(find.text("/review"));
      await tester.pump();

      expect(typed(tester), "/review about the parser");
    });

    // A mention is read anywhere a word starts, so it goes where the caret is.
    testWidgets("an agent lands at the caret", (tester) async {
      await openBlank(tester);
      await tester.enterText(find.byType(TextField), "look here");
      await tester.pump();

      await tester.tap(find.text("@explore"));
      await tester.pump();

      expect(typed(tester), "look here @explore ");
    });

    testWidgets("with nothing to offer it says how to reach them",
        (tester) async {
      app.dispose();
      app = TestApp.create(library: PromptLibrary.empty);
      await openBlank(tester);

      expect(find.text("Type / for commands, @ for agents."), findsOneWidget);
    });

    // Everything the user has written is a menu, and `/` opens the menu.
    testWidgets("offers a handful rather than every command there is",
        (tester) async {
      app.dispose();
      app = TestApp.create(
        library: PromptLibrary([
          for (var i = 0; i < 12; i++)
            PromptDocument.parse(CompletionKind.skill, "cmd$i", "do $i"),
        ]),
      );
      await openBlank(tester);

      expect(find.byType(ActionChip), findsNWidgets(6));
    });
  });

  group("keeping up with a turn", () {
    testWidgets("there is no jump button while the end is in view", (tester) async {
      final chat = await seedLongChat(tester);

      await open(tester, chat.state.id);

      expect(find.byTooltip("Jump to latest"), findsNothing);
    });

    testWidgets("scrolling back offers the way down again", (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(find.byTooltip("Jump to latest"), findsOneWidget);

      await tester.tap(find.byTooltip("Jump to latest"));
      await tester.pumpAndSettle();

      expect(position(tester).pixels, position(tester).maxScrollExtent);
      expect(find.byTooltip("Jump to latest"), findsNothing);
    });

    testWidgets("a reply arriving while the reader is up the page leaves it there",
        (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      final held = position(tester).pixels;

      app.backend.scriptedEvents = [const TextDelta("and another thing"), const DoneEvent()];
      await io(
        tester,
        () => app.container.read(chatControllerProvider(chat.state.id).notifier).send("more"),
      );
      await settleIo(tester);

      expect(position(tester).pixels, held);
      expect(find.byTooltip("Jump to latest"), findsOneWidget);
    });
  });

  group("a turn that never finished", () {
    testWidgets("is offered to be carried on", (tester) async {
      final chat = await seedLongChat(tester, messages: 2, finished: false);

      await open(tester, chat.state.id);

      expect(find.text("Continue"), findsOneWidget);
      expect(find.textContaining("Unfinished turn"), findsOneWidget);
    });

    testWidgets("a finished one is not", (tester) async {
      final chat = await seedLongChat(tester, messages: 2);

      await open(tester, chat.state.id);

      expect(find.text("Continue"), findsNothing);
    });

    testWidgets("the offer goes once it is taken", (tester) async {
      final chat = await seedLongChat(tester, messages: 2, finished: false);
      await open(tester, chat.state.id);

      app.backend.scriptedEvents = const [TextDelta(" — two files"), DoneEvent()];
      await tester.tap(find.text("Continue"));
      await settleIo(tester);

      expect(find.text("Continue"), findsNothing);
      expect(app.backend.resumes, hasLength(1));
    });
  });

  /// How visible each message's row of actions currently is.
  Iterable<double> revealed(WidgetTester tester) => tester
      .widgetList<AnimatedOpacity>(find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(AnimatedOpacity),
      ))
      .map((o) => o.opacity);

  // Only the message that was touched: each keeps its own actions covered.
  testWidgets("touching a message uncovers that one's actions", (tester) async {
    final chat = await seedLongChat(tester, messages: 4);
    await open(tester, chat.state.id);

    await tester.tap(find.text("line 0"), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(MessageBubble), findsNWidgets(4));
    expect(revealed(tester).where((o) => o == 1), hasLength(1));
  });

  // Starting a scroll on a message is not the same as touching it.
  testWidgets("dragging the list from a message leaves it covered", (tester) async {
    final chat = await seedLongChat(tester);
    await open(tester, chat.state.id);

    final gesture = await tester.startGesture(tester.getCenter(find.text("line 39")));
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text("line 39"), findsOneWidget);
    expect(revealed(tester).where((o) => o == 1), isEmpty);
  });

  group("when a memory note lands", () {
    testWidgets("the chat the note is about says so in a line", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "noted"));
      await open(tester, chat.state.id);

      app.backend
          .memoryNoteHolder
          .add(MemoryNote(chat.state.id, "Kept 1 memory."));
      // Two frames: the messenger rebuilds, and the snackbar attaches on the
      // frame after.
      await tester.pump();
      await tester.pump();

      expect(find.text("Kept 1 memory."), findsOneWidget);
    });

    testWidgets("a note for another chat is not this page's line", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "noted"));
      await open(tester, chat.state.id);

      app.backend.memoryNoteHolder.add(
          MemoryNote("some-other-chat", "Kept 1 memory."));
      await tester.pump();
      await tester.pump();

      expect(find.text("Kept 1 memory."), findsNothing);
    });
  });
}
