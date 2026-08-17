import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/project.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The wide layout: the sidebar sits beside the chat pane, no drawer.
  Future<void> pumpBeside(WidgetTester tester, {EdgeInsets bars = EdgeInsets.zero}) =>
      app.pump(
        tester,
        underSystemBars(
          bars,
          const Row(children: [SizedBox(width: 280, child: Sidebar())]),
        ),
      );

  /// The narrow layout: the sidebar is a drawer over the chat.
  Future<void> pumpAsDrawer(WidgetTester tester, {EdgeInsets bars = EdgeInsets.zero}) async {
    await app.pump(
      tester,
      underSystemBars(
        bars,
        Scaffold(
          drawer: const Drawer(child: Sidebar()),
          body: const SizedBox.shrink(),
          appBar: AppBar(
            leading: Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await settleIo(tester);
  }

  testWidgets("the new chat button selects the chat it just created", (tester) async {
    await pumpBeside(tester);
    expect(app.container.read(selectedChatIdProvider), isNull);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNotNull);
  });

  testWidgets("a new chat is not listed until something is said in it", (tester) async {
    await io(tester, () => app.seedChat());
    await pumpBeside(tester);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(await io(tester, () => app.repo.listChats()), hasLength(1));
    expect(find.text("New chat"), findsNothing);
    expect(find.text("old chat"), findsOneWidget);
  });

  testWidgets("its first message puts it in the list", (tester) async {
    await pumpBeside(tester);
    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);
    final id = app.container.read(selectedChatIdProvider)!;

    final controller = app.container.read(chatControllerProvider(id).notifier);
    await tester.runAsync(() async {
      // The controller loads its chat before it can send anything.
      await Future<void>.delayed(Duration.zero);
      await controller.send("hello");
    });
    await pumpUntil(tester, find.text("New chat"));
    await settleIo(tester);

    expect(find.text("New chat"), findsOneWidget);
    expect(await io(tester, () => app.repo.listChats()), hasLength(1));
  });

  testWidgets("a second new chat becomes the selected one", (tester) async {
    await pumpBeside(tester);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);
    final first = app.container.read(selectedChatIdProvider);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNot(first));
  });

  testWidgets("creating a chat from the drawer closes it", (tester) async {
    await pumpAsDrawer(tester);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("tapping an existing chat in the drawer closes it too", (tester) async {
    await io(tester, () => app.seedChat());
    await pumpAsDrawer(tester);

    await tester.tap(find.text("old chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets("selecting beside the chat pane leaves the sidebar in place", (tester) async {
    await io(tester, () => app.seedChat());
    await pumpBeside(tester);

    await tester.tap(find.text("old chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNotNull);
    expect(find.byType(Sidebar), findsOneWidget);
  });

  group("what the list looks like", () {
    /// A chat last touched [daysAgo], which is what decides the heading it
    /// lands under. Written straight to the store: the repository stamps
    /// `updatedAt` itself, and the date is the whole subject here.
    Future<void> seedDated(WidgetTester tester, String title, int daysAgo) =>
        io(tester, () async {
          final chat = await app.repo.createChat(title: title);
          await app.repo.saveState(chat.state.copyWith(
            updatedAt: DateTime.now().subtract(Duration(days: daysAgo)),
          ));
        });

    testWidgets("chats sit under a heading for when they were last touched",
        (tester) async {
      await seedDated(tester, "this one", 0);
      await seedDated(tester, "that one", 1);
      await seedDated(tester, "the old one", 12);
      await pumpBeside(tester);

      expect(find.text("Today"), findsOneWidget);
      expect(find.text("Yesterday"), findsOneWidget);
      expect(find.text("Previous 30 days"), findsOneWidget);
    });

    testWidgets("a project with nothing in it says so and offers no search",
        (tester) async {
      await pumpBeside(tester);

      expect(find.text("No chats in this project yet."), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets("typing in the search box leaves only what matches",
        (tester) async {
      await io(tester, () => app.seedChat(title: "porting the shell"));
      await io(tester, () => app.seedChat(title: "the icon"));
      await pumpBeside(tester);

      await tester.enterText(find.byType(TextField), "shell");
      await tester.pump();

      expect(find.text("porting the shell"), findsOneWidget);
      expect(find.text("the icon"), findsNothing);
    });

    testWidgets("a search nothing answers says so rather than going blank",
        (tester) async {
      await io(tester, () => app.seedChat(title: "the icon"));
      await pumpBeside(tester);

      await tester.enterText(find.byType(TextField), "compiler");
      await tester.pump();

      expect(find.text("No chat's title matches that."), findsOneWidget);
      // The field stays, or there would be no way to undo the search.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets("clearing the search puts the rest back", (tester) async {
      await io(tester, () => app.seedChat(title: "porting the shell"));
      await io(tester, () => app.seedChat(title: "the icon"));
      await pumpBeside(tester);
      await tester.enterText(find.byType(TextField), "shell");
      await tester.pump();

      await tester.tap(find.byTooltip("Clear search"));
      await tester.pump();

      expect(find.text("the icon"), findsOneWidget);
      expect(find.text("porting the shell"), findsOneWidget);
    });
  });

  const bars = EdgeInsets.only(top: 40, bottom: 48);

  /// Nothing at either end of the sidebar is under a system bar.
  void expectClearOfBars(WidgetTester tester) {
    final sidebar = tester.getRect(find.byType(Sidebar));
    final top = tester.getRect(find.text(projectLabel(null)));
    final bottom = tester.getRect(find.text("Settings"));
    expect(top.top - sidebar.top, greaterThanOrEqualTo(bars.top));
    expect(sidebar.bottom - bottom.bottom, greaterThanOrEqualTo(bars.bottom));
  }

  testWidgets("beside the chat pane it stays clear of the system bars", (tester) async {
    await pumpBeside(tester, bars: bars);

    expectClearOfBars(tester);
  });

  testWidgets("as a drawer it stays clear of them too", (tester) async {
    await pumpAsDrawer(tester, bars: bars);

    expectClearOfBars(tester);
  });

  group("projects", () {
    /// Open the switcher at the top of the sidebar, whatever it currently says.
    Future<void> openProjectMenu(WidgetTester tester) async {
      await tester.tap(find.text(projectLabel(app.container.read(selectedProjectProvider))));
      await settleIo(tester);
    }

    Future<void> switchTo(WidgetTester tester, String label) async {
      await openProjectMenu(tester);
      await tester.tap(find.text(label).last);
      await settleIo(tester);
    }

    testWidgets("the sidebar opens in the default project", (tester) async {
      await pumpBeside(tester);

      expect(app.container.read(selectedProjectProvider), isNull);
      expect(find.text("Default"), findsOneWidget);
    });

    testWidgets("only the chats of the project shown are listed", (tester) async {
      await io(tester, () => app.seedChat(title: "at home"));
      await io(tester, () => app.seedChat(title: "at work", project: "work"));
      await pumpBeside(tester);

      expect(find.text("at home"), findsOneWidget);
      expect(find.text("at work"), findsNothing);

      await switchTo(tester, "work");

      expect(find.text("at work"), findsOneWidget);
      expect(find.text("at home"), findsNothing);
    });

    // A chat of the project just left is not in the list any more.
    testWidgets("switching projects deselects the chat that was open", (tester) async {
      await io(tester, () => app.seedChat(title: "at home"));
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(tester);

      await tester.tap(find.text("at home"));
      await settleIo(tester);
      expect(app.container.read(selectedChatIdProvider), isNotNull);

      await switchTo(tester, "work");

      expect(app.container.read(selectedChatIdProvider), isNull);
    });

    testWidgets("a new chat is created in the project being shown", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(tester);
      await switchTo(tester, "work");

      await tester.tap(find.byTooltip("New chat"));
      await settleIo(tester);

      final id = app.container.read(selectedChatIdProvider)!;
      expect(await io(tester, () => app.repo.projectOf(id)), "work");
    });

    testWidgets("creating one names it, lays it down and switches to it", (tester) async {
      await pumpBeside(tester);
      await openProjectMenu(tester);

      await tester.tap(find.text("New project…"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), "My Side Project");
      await tester.tap(find.text("Create"));
      await settleIo(tester);

      expect(app.container.read(selectedProjectProvider), "My-Side-Project");
      expect(Directory(app.config.projectWorkspaceDir(project: "My-Side-Project")).existsSync(), isTrue);
    });

    testWidgets("deleting one takes its chats and goes back to the default", (tester) async {
      await io(tester, () => app.seedChat(title: "at work", project: "work"));
      await pumpBeside(tester);
      await switchTo(tester, "work");

      await openProjectMenu(tester);
      await tester.tap(find.text("Delete project…"));
      await settleIo(tester);
      await tester.tap(find.text("Delete"));
      await settleIo(tester, least: 20);

      expect(app.container.read(selectedProjectProvider), isNull);
      expect(await io(tester, () => app.repo.listChats()), isEmpty);
      expect(Directory(app.config.projectDir(project: "work")).existsSync(), isFalse);
    });

    testWidgets("moving a chat follows it into the project it went to", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "at home"));
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await settleIo(tester);
      await tester.tap(find.text("Move to project…"));
      await settleIo(tester, least: 20);
      await tester.tap(find.text("work"));
      await settleIo(tester, least: 20);

      expect(await io(tester, () => app.repo.projectOf(chat.state.id)), "work");
      expect(app.container.read(selectedProjectProvider), "work");
      // The list was invalidated by the move; it has to be read again to show it.
      await pumpUntil(tester, find.text("at home"));
      expect(find.text("at home"), findsOneWidget);
    });

    // The switcher is one menu in both layouts, and back has to mean the same
    // thing in each: dismiss the menu, leave what is behind it alone.
    group("the back key", () {
      testWidgets("beside the chat, closes the menu instead of the app", (tester) async {
        await pumpBeside(tester);
        await openProjectMenu(tester);
        expect(find.text("New project…"), findsOneWidget);

        expect(await pressBack(tester), isTrue);

        expect(find.text("New project…"), findsNothing);
        expect(find.byType(Sidebar), findsOneWidget);
      });

      testWidgets("as a drawer, closes the menu and leaves the sidebar open", (tester) async {
        await pumpAsDrawer(tester);
        await openProjectMenu(tester);
        expect(find.text("New project…"), findsOneWidget);

        expect(await pressBack(tester), isTrue);

        expect(find.text("New project…"), findsNothing);
        expect(find.byType(Sidebar), findsOneWidget);
      });

      // Only once the menu is out of the way does back reach the drawer — and
      // the app has to still hold the key by then, or the second press never
      // arrives to be answered.
      testWidgets("closes the drawer on the second press", (tester) async {
        final claimed = frameworkHandlesBack(tester);
        await pumpAsDrawer(tester);
        await openProjectMenu(tester);
        await pressBack(tester);
        expect(claimed.last, isTrue);

        expect(await pressBack(tester), isTrue);

        expect(find.byType(Sidebar), findsNothing);
      });
    });
  });
}
