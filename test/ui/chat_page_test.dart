import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/voice/voice_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

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
    Future<void> openEmpty(WidgetTester tester) =>
        app.pump(tester, const ChatPage(withDrawer: true));

    testWidgets("the ways to have a conversation are offered, in order",
        (tester) async {
      await openEmpty(tester);

      expect(find.text("New Chat"), findsOneWidget);
      expect(find.text("New Voice Chat"), findsOneWidget);
      expect(find.text("Open Chat"), findsOneWidget);
      // New Voice Chat is an extension of New Chat, so it sits with it rather
      // than beside the way to open an old one.
      expect(tester.getCenter(find.text("New Voice Chat")).dy,
          greaterThan(tester.getCenter(find.text("New Chat")).dy));
      expect(tester.getCenter(find.text("New Voice Chat")).dy,
          lessThan(tester.getCenter(find.text("Open Chat")).dy));
    });

    testWidgets("New Voice Chat makes one and opens it in voice mode",
        (tester) async {
      app.dispose();
      app = TestApp.create(voiceModels: voiceModelPair);
      await io(tester, app.pickVoiceModels);
      await openEmpty(tester);

      await tester.tap(find.text("New Voice Chat"));
      // Not settled: the orb listens on, so a screen with one on it never
      // falls still.
      await pumpUntil(tester, find.byType(VoicePage));

      expect(app.container.read(selectedChatIdProvider), isNotNull);
      expect(find.byType(VoicePage), findsOneWidget);
    });

    testWidgets("with no models it offers settings and makes no chat",
        (tester) async {
      await openEmpty(tester);

      await tester.tap(find.text("New Voice Chat"));
      await settleIo(tester);

      expect(find.text("Open settings"), findsOneWidget);
      // A chat created and then left behind because there is nothing to say it
      // with is a worse answer than not creating one.
      expect(app.container.read(selectedChatIdProvider), isNull);
    });

    testWidgets("New Chat opens one", (tester) async {
      await openEmpty(tester);

      await tester.tap(find.text("New Chat"));
      await settleIo(tester);

      expect(app.container.read(selectedChatIdProvider), isNotNull);
      expect(find.byType(Composer), findsOneWidget);
    });

    testWidgets("Open Chat slides the sidebar out", (tester) async {
      await io(tester, () => app.seedChat(title: "old chat"));
      await openEmpty(tester);

      await tester.tap(find.text("Open Chat"));
      await settleIo(tester);

      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.text("old chat"), findsOneWidget);
    });

    // The sidebar is already beside the pane there, so there is nothing to open.
    testWidgets("and there is nothing to open where the sidebar is already out",
        (tester) async {
      await app.pump(tester, const ChatPage());

      expect(find.text("New Chat"), findsOneWidget);
      expect(find.text("Open Chat"), findsNothing);
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

    Future<String?> projectOfNewChat(WidgetTester tester) async {
      await tester.tap(find.text("New Chat"));
      await settleIo(tester);
      return io(tester, () => app.repo.projectOf(app.container.read(selectedChatIdProvider)!));
    }

    // The default project has no badge: it is nothing selected.
    testWidgets("the named projects are badges", (tester) async {
      await openWithProject(tester);

      expect(find.widgetWithText(ChoiceChip, "work"), findsOneWidget);
      expect(find.text(defaultProjectLabel), findsNothing);
      expect(selectedOf(tester, "work"), isFalse);
    });

    testWidgets("and there are none until one is made", (tester) async {
      await openEmpty(tester);

      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets("picking one highlights it and takes the next chat with it",
        (tester) async {
      await openWithProject(tester);

      await pick(tester, "work");

      expect(selectedOf(tester, "work"), isTrue);
      expect(app.container.read(selectedProjectProvider), "work");
      expect(await projectOfNewChat(tester), "work");
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
    });

    // Pressing a button is not where the project changes — the badge is.
    testWidgets("New Chat lands in the default until a badge is picked",
        (tester) async {
      await openWithProject(tester);

      expect(await projectOfNewChat(tester), isNull);
    });

    testWidgets("Open Chat shows the picked project's chats", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await io(tester, () => app.seedChat(title: "at work", project: "work"));
      await io(tester, () => app.seedChat(title: "at home"));
      await openEmpty(tester);

      await pick(tester, "work");
      await tester.tap(find.text("Open Chat"));
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
    expect(find.text("Entoli"), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at work")),
        findsOneWidget);
    expect(find.text("Entoli"), findsNothing);
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

  // The case the scroll-position bar got wrong: nothing to scroll used to mean
  // the app's name over every chat short enough to fit.
  testWidgets("a chat with nothing to scroll is named too", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "brand new"));

    await open(tester, chat.state.id);

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("brand new")),
        findsOneWidget);
    expect(find.text("Entoli"), findsNothing);
  });

  // Three lines — a title, a project and a countdown — do not fit the 56dp bar
  // every other chat gets, and the last of them was being clipped.
  testWidgets("a chat that is both in a project and temporary fits its bar",
      (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "at work", project: "work"));
    await io(tester, () => app.makeTemporary(chat.state));

    await open(tester, chat.state.id);

    final bar = find.byType(AppBar);
    expect(find.descendant(of: bar, matching: find.text("work")), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.byIcon(Icons.hourglass_empty)),
        findsOneWidget);
    // The lines are laid out inside the bar, so one too short to hold them
    // overflows, which fails the test before this reads anything.
    expect(tester.getSize(bar).height, greaterThan(kToolbarHeight));
  });

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

    String typed(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

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
    // `BuiltinBackend._command` only reads one at the start of the message,
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
            PromptDocument.parse(CompletionKind.command, "cmd$i", "do $i"),
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
}
