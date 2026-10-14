import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/sidebar/chat_groups.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/ui/workspace/workspace_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// The wide layout: the sidebar sits beside the chat pane, no drawer. [beside]
  /// is that pane, for the tests about what the sidebar does to the chat it is
  /// not.
  Future<void> pumpBeside(
    WidgetTester tester, {
    EdgeInsets bars = EdgeInsets.zero,
    Widget? beside,
  }) =>
      app.pump(
        tester,
        underSystemBars(
          bars,
          Row(children: [
            const SizedBox(width: 280, child: Sidebar()),
            if (beside != null) Expanded(child: beside),
          ]),
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

  // The button goes to the new-chat screen rather than making anything: what
  // it does is drop the selection, and nothing selected is that screen.
  testWidgets("the new chat button drops the selection and writes nothing",
      (tester) async {
    await io(tester, app.openSomeChat);
    await pumpBeside(tester);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNull);
    expect(await io(tester, () => app.repo.listChats()), hasLength(1));
    expect(find.text("New chat"), findsNothing);
    expect(find.text("old chat"), findsOneWidget);
  });

  /// A row in the list, rather than the same words in the chat pane's title
  /// bar beside it.
  Finder listed(String title) =>
      find.descendant(of: find.byType(Sidebar), matching: find.text(title));

  /// Open a chat row's context menu. Shared by the pinning and deleting groups,
  /// which both tap the same `more_vert` trigger.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await settleIo(tester);
  }

  // The list is what the new-chat screen's first message reaches, and it only
  // reaches it because creating the chat invalidates it.
  testWidgets("its first message puts it in the list", (tester) async {
    await pumpBeside(tester, beside: const ChatPage());
    expect(listed("New chat"), findsNothing);

    await sendMessage(tester, "hello");
    await pumpUntil(tester, listed("New chat"));

    expect(listed("New chat"), findsOneWidget);
    expect(await io(tester, () => app.repo.listChats()), hasLength(1));
  });

  testWidgets("the new chat button closes the drawer it was pressed in",
      (tester) async {
    await io(tester, app.openSomeChat);
    await pumpAsDrawer(tester);

    await tester.tap(find.byTooltip("New chat"));
    await settleIo(tester);

    expect(app.container.read(selectedChatIdProvider), isNull);
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

    // The list it was written against has just been replaced, which is also why
    // switching clears the selected chat.
    testWidgets("switching projects clears the search", (tester) async {
      await io(tester, () => app.seedChat(title: "porting the shell"));
      await io(tester, () => app.seedChat(title: "at work", project: "work"));
      await pumpBeside(tester);
      await tester.enterText(find.byType(TextField), "shell");
      await tester.pump();

      app.container.read(selectedProjectProvider.notifier).select("work");
      await settleIo(tester);

      expect(find.text("at work"), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
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

    // The slot beside the switcher is whatever the project it names can be
    // asked about: a named one has a settings page, the default one has only
    // its workspace.
    testWidgets("the default project's button goes to its workspace", (tester) async {
      await pumpBeside(tester);

      expect(find.byTooltip("Project settings"), findsNothing);
      await tester.tap(find.byTooltip("Default workspace"));
      await settleIo(tester);

      // That it is the right root is workspace_page_test's.
      expect(find.byType(WorkspacePage), findsOneWidget);
    });

    // A built-in project is in the menu like any other, but it is not one the
    // user made, so there is nothing to delete it with.
    testWidgets("a built-in project is offered, and not deletable", (tester) async {
      await pumpBeside(tester);
      await openProjectMenu(tester);

      expect(find.text(anonProjectLabel), findsOneWidget);
      expect(find.text("Delete project…"), findsNothing);
    });

    // Anonymous has neither a settings page nor a shared workspace, so the
    // slot beside the switcher holds nothing for it. Byte Repair has both,
    // since its spec ships a note and reads the user's files on top of it.
    testWidgets("anonymous has no settings page or workspace button", (tester) async {
      await pumpBeside(tester);
      await switchTo(tester, anonProjectLabel);

      expect(app.container.read(selectedProjectProvider), "anonymous");
      expect(find.byTooltip("Project settings"), findsNothing);
      expect(find.byTooltip("Default workspace"), findsNothing);
    });

    testWidgets("Byte Repair has a settings gear that opens its page",
        (tester) async {
      await pumpBeside(tester);
      await switchTo(tester, byteRepairProjectLabel);

      expect(app.container.read(selectedProjectProvider), "byte-repair");
      expect(find.byTooltip("Project settings"), findsOneWidget);
      await tester.tap(find.byTooltip("Project settings"));
      await settleIo(tester);

      expect(find.byType(ProjectSettingsPage), findsOneWidget);
    });

    testWidgets("a named project's still goes to its settings", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(tester);
      await switchTo(tester, "work");

      expect(find.byTooltip("Default workspace"), findsNothing);
      await tester.tap(find.byTooltip("Project settings"));
      await settleIo(tester);

      expect(find.byType(ProjectSettingsPage), findsOneWidget);
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

    // The switcher says where the next chat goes, and the next chat is made by
    // the first thing said on the screen switching to it lands on.
    testWidgets("a new chat is created in the project being shown", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(tester, beside: const ChatPage());
      await switchTo(tester, "work");

      await sendMessage(tester, "hello");
      await pumpUntil(tester, listed("New chat"));

      expect((await io(tester, () => app.repo.listChats())).single.project, "work");
    });

    testWidgets("creating one names it, lays it down and switches to it", (tester) async {
      await pumpBeside(tester);
      await openProjectMenu(tester);

      await tester.tap(find.text("New project…"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), "My Side Project");
      await tester.tap(find.text("Create"));
      await settleIo(tester, least: 20);

      expect(app.container.read(selectedProjectProvider), "My-Side-Project");
      expect(Directory(app.config.projectWorkspaceDir(project: "My-Side-Project")).existsSync(), isTrue);
    });

    testWidgets("creating one with the switch on writes the Omada flag", (tester) async {
      await pumpBeside(tester);
      await openProjectMenu(tester);

      await tester.tap(find.text("New project…"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), "Team");
      await tester.tap(find.byType(SwitchListTile));
      await settleIo(tester);
      await tester.tap(find.text("Create"));
      await settleIo(tester, least: 20);

      await io(tester, () async {});
      expect(
        ProjectSettings.load(app.config, project: "Team").omada,
        isTrue,
      );
    });

    testWidgets("creating one with the switch off leaves Omada off", (tester) async {
      await pumpBeside(tester);
      await openProjectMenu(tester);

      await tester.tap(find.text("New project…"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), "Plain");
      await tester.tap(find.text("Create"));
      await settleIo(tester, least: 20);

      expect(ProjectSettings.load(app.config, project: "Plain").omada, isFalse);
    });

    testWidgets("an Omada project's name is italic in the menu, a plain one is not", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await io(tester, () async {
        await app.repo.createProject("team");
        await app.container
            .read(projectSettingsProvider("team").notifier)
            .setOmada(true);
      });
      await pumpBeside(tester);
      await openProjectMenu(tester);

      // The menu rows live below `find.byType(PopupMenuItem)`'s reach once
      // `settleIo` has run — read the text widget itself.
      expect(tester.widget<Text>(find.text("team")).style?.fontStyle,
          FontStyle.italic);
      expect(tester.widget<Text>(find.text("work")).style?.fontStyle, isNull);
    });

    testWidgets("the selected button's label is italic for an Omada project", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("team");
        await app.container
            .read(projectSettingsProvider("team").notifier)
            .setOmada(true);
      });
      await pumpBeside(tester);
      await switchTo(tester, "team");

      final label = find
          .descendant(
            of: find.byType(TextButton),
            matching: find.text("team"),
          )
          .first;
      expect(tester.widget<Text>(label).style?.fontStyle, FontStyle.italic);
    });

    testWidgets("the settings page's toggle reveals the ordering section", (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      await app.pump(tester, ProjectSettingsPage(project: "research"));

      expect(find.text("Round order"), findsNothing);
      await tester.scrollUntilVisible(
        find.text("Omada"),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await settleIo(tester);
      await tester.tap(find.text("Omada"));
      await settleIo(tester, least: 10);

      expect(find.text("Round order"), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<OmadaOrdering?>));
      await settleIo(tester);
      await tester.tap(find.text("Crossfire").last);
      await settleIo(tester, least: 10);

      await io(tester, () async {});
      final settings = ProjectSettings.load(app.config, project: "research");
      expect(settings.omada, isTrue);
      expect(settings.omadaOrdering, OmadaOrdering.parallel);
    });

    testWidgets("a built-in's settings page has no Omada toggle or Description row", (tester) async {
      await app.pump(
        tester,
        ProjectSettingsPage(project: byteRepairProjectLabel.toLowerCase()),
      );

      // A built-in's answer is its spec: the page says it, rather than
      // offering a toggle to change it. The ordering rows ride the same
      // answer — My Team's page shows them, Byte Repair's shows nothing.
      expect(find.text("Omada"), findsOneWidget);
      expect(find.text("Round order"), findsNothing);
      // And the Description row is the named projects' alone.
      expect(find.text("Description"), findsNothing);
    });

    testWidgets("My Team's settings page shows the Omada state, not a toggle",
        (tester) async {
      await app.pump(tester, ProjectSettingsPage(project: "my-team"));

      // The card sections sit above it, so the row is below the fold.
      await tester.scrollUntilVisible(
        find.text("Omada"),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await settleIo(tester);

      // The one row, rendered with the switch disabled — a built-in's answer
      // is its spec, so the state is shown, not offered. The ordering rows
      // ride the same answer and are offered.
      final toggle = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, "Omada"));
      expect(toggle.value, isTrue);
      expect(toggle.onChanged, isNull);
      expect(find.text("Round order"), findsOneWidget);
    });

    // The row is the description's own surface: open, edit, save, and the
    // screen reads it back.
    testWidgets("the Description row edits through its dialog", (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      await app.pump(tester, const ProjectSettingsPage(project: "research"));

      expect(find.text("Description"), findsOneWidget);
      // Unset, it names what the screen would ask.
      expect(find.text("What would you like to discuss?"), findsOneWidget);

      await tester.tap(find.text("Description"));
      await settleIo(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text("What would you like to discuss?"), findsNWidgets(2));

      await tester.enterText(find.byType(TextField), "What are we building?");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 10);

      await io(tester, () async {});
      expect(
          ProjectSettings.load(app.config, project: "research").description,
          "What are we building?");
      expect(find.text("What are we building?"), findsOneWidget);
    });

    // Empty is saved as it stands — the screen asks nothing — and the reset
    // button, not a blank save, is what puts the default back.
    testWidgets("an empty save clears the question and reset restores it", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("research");
        await app.container
            .read(projectSettingsProvider("research").notifier)
            .setDescription("What are we building?");
      });
      await app.pump(tester, const ProjectSettingsPage(project: "research"));

      await tester.tap(find.text("Description"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), "");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 10);

      await io(tester, () async {});
      expect(ProjectSettings.load(app.config, project: "research").description,
          "");
      expect(find.text("Empty"), findsOneWidget);

      await tester.tap(find.byTooltip("Reset to default"));
      await settleIo(tester, least: 10);

      await io(tester, () async {});
      expect(ProjectSettings.load(app.config, project: "research").description,
          isNull);
      expect(find.text("Empty"), findsNothing);
      expect(find.text("What would you like to discuss?"), findsOneWidget);
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

    testWidgets("deleting one the assistant opens in unpicks it", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("work");
        await app.container
            .read(appSettingsProvider.notifier)
            .setAssistantProject("work");
      });
      await pumpBeside(tester);
      await switchTo(tester, "work");

      await openProjectMenu(tester);
      await tester.tap(find.text("Delete project…"));
      await settleIo(tester);
      await tester.tap(find.text("Delete"));
      await settleIo(tester, least: 20);

      // Left written down it would be written back by the next save, and a
      // project made under the same name again would re-arm the setting.
      expect(AppSettings.load(app.config).assistantProject, isNull);
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
      // The list was invalidated by the move; it has to be read again to show
      // it. The selection is set at the end of the same chain, so it is read
      // once the rebuild has landed rather than on a round count.
      await pumpUntil(tester, find.text("at home"));
      expect(find.text("at home"), findsOneWidget);
      expect(app.container.read(selectedProjectProvider), "work");
    });

    // The open controller held the chat as it was when it read it — project
    // included — so a move disposes it and the page reloads from where the
    // chat now is. The title bar names the new project from the next read.
    testWidgets("moving the open chat reloads its page in the new project",
        (tester) async {
      await io(tester, () async {
        final chat = await app.seedChat(title: "at home");
        app.container
            .read(selectedChatIdProvider.notifier)
            .select(chat.state.id);
        return chat;
      });
      await io(tester, () => app.repo.createProject("work"));
      await pumpBeside(
        tester,
        beside: SizedBox(width: 300, child: ChatPage(withDrawer: false)),
      );
      await settleIo(tester);
      expect(find.text("Default"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert));
      await settleIo(tester);
      await tester.tap(find.text("Move to project…"));
      await settleIo(tester, least: 20);
      await tester.tap(find.text("work").last);
      await settleIo(tester, least: 20);

      // The page was invalidated by the move; the reload draws the new project.
      await pumpUntil(tester, find.text("work"));
      expect(find.text("work"), findsWidgets);
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

  group("pinning", () {
    testWidgets("the context menu offers Pin on an unpinned chat", (tester) async {
      await io(tester, () => app.seedChat(title: "a chat"));
      await pumpBeside(tester);

      await openMenu(tester);

      expect(find.text("Pin"), findsOneWidget);
      expect(find.text("Unpin"), findsNothing);
    });

    testWidgets("pinning moves the chat under the Pinned heading", (tester) async {
      await io(tester, () => app.seedChat(title: "to pin"));
      await pumpBeside(tester);

      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));

      expect(find.text(pinnedHeading), findsOneWidget);
      expect(find.text("to pin"), findsOneWidget);
      // The date group it was in is gone — the chat left it.
      expect(find.text("Today"), findsNothing);
    });

    testWidgets("the menu offers Unpin once it is pinned", (tester) async {
      await io(tester, () => app.seedChat(title: "to pin"));
      await pumpBeside(tester);
      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);

      await openMenu(tester);

      expect(find.text("Unpin"), findsOneWidget);
      expect(find.text("Pin"), findsNothing);
    });

    testWidgets("unpinning moves the chat back to its date group", (tester) async {
      await io(tester, () => app.seedChat(title: "to pin"));
      await pumpBeside(tester);
      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);

      await openMenu(tester);
      await tester.tap(find.text("Unpin"));
      await pumpUntil(tester, find.text("Today"));

      expect(find.text(pinnedHeading), findsNothing);
      expect(find.text("Today"), findsOneWidget);
      expect(find.text("to pin"), findsOneWidget);
    });

    testWidgets("pinning a temporary chat clears its expiry", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "temp"));
      await io(tester, () => app.makeTemporary(chat.state));
      await pumpBeside(tester);
      // The hourglass says it is temporary.
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);

      expect(find.byIcon(Icons.hourglass_empty), findsNothing);
      final saved = await io(tester, () => app.repo.openChat(chat.state.id));
      expect(saved.state.pinned, isTrue);
      expect(saved.state.tempTtlExpiresAt, isNull);
      expect(saved.state.tempTtlSince, isNull);
    });

    // The countdown is drawn from the open chat's own state, which the sidebar
    // does not go through — so pinning used to leave the bar counting down to
    // an expiry that had just been cleared, until the chat was opened again.
    testWidgets("pinning the open chat stops its title bar counting down",
        (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "temp"));
      await io(tester, () => app.makeTemporary(chat.state));
      app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
      await pumpBeside(tester, beside: const ChatPage());
      final bar = find.byType(AppBar);
      expect(find.descendant(of: bar, matching: find.byIcon(Icons.hourglass_empty)),
          findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);

      expect(find.descendant(of: bar, matching: find.byIcon(Icons.hourglass_empty)),
          findsNothing);
      expect(find.descendant(of: bar, matching: find.text("Pinned")), findsOneWidget);
    });

    testWidgets("pinning sets the chat's TTL override to off", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "to pin"));
      await io(tester, () => app.seedChatMeta(chat.state.id,
          ChatMeta(tempChatTtl: TempChatTtl.hours24)));

      await pumpBeside(tester);
      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);

      final meta = await io(tester, () => app.savedMeta(chat.state.id));
      expect(meta.tempChatTtl, TempChatTtl.off);
    });

    testWidgets("unpinning leaves the TTL override at off", (tester) async {
      final chat = await io(tester, () => app.seedChat(title: "to pin"));
      await pumpBeside(tester);
      await openMenu(tester);
      await tester.tap(find.text("Pin"));
      await pumpUntil(tester, find.text(pinnedHeading));
      await settleIo(tester);
      await openMenu(tester);
      await tester.tap(find.text("Unpin"));
      await pumpUntil(tester, find.text("Today"));
      await settleIo(tester);

      final meta = await io(tester, () => app.savedMeta(chat.state.id));
      expect(meta.tempChatTtl, TempChatTtl.off);
    });
  });
  group("deleting", () {
    Future<void> confirmDelete(WidgetTester tester) async {
      await tester.tap(find.text("Delete"));
      await pumpUntil(tester, find.text("Delete chat?"));
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text("Delete")));
      await settleIo(tester);
    }

    // The only thing that used to refresh the sidebar on a local deletion was
    // the deleting widget's own ref.invalidate, called after awaits — and
    // nothing reacted to the repo's Deleted event locally. When that invalidate
    // did not take hold the row stayed in the list pointing at a chat whose data
    // was gone.
    testWidgets("deleting the open chat drops it from the list and closes it",
        (tester) async {
      await io(tester, app.openSomeChat);
      await pumpBeside(tester, beside: const ChatPage());
      expect(listed("old chat"), findsOneWidget);

      await openMenu(tester);
      await confirmDelete(tester);

      expect(listed("old chat"), findsNothing);
      expect(app.container.read(selectedChatIdProvider), isNull);
      expect(await io(tester, () => app.repo.listChats()), isEmpty);
    });

    // The controller is not auto-disposed, so before the fix it stayed alive
    // holding the deleted chat in memory: selecting its id again opened the
    // cached conversation rather than an empty page.
    testWidgets("re-selecting the deleted chat's id does not open its cached view",
        (tester) async {
      final chat = await io(tester, app.openSomeChat);
      await pumpBeside(tester, beside: const ChatPage());
      await openMenu(tester);
      await confirmDelete(tester);

      app.container
          .read(selectedChatIdProvider.notifier)
          .select(chat.state.id);
      await tester.pump();

      final pane = find.byType(ChatPage);
      expect(
          find.descendant(of: pane, matching: find.text("old chat")),
          findsNothing);
    });
  });
  group("a project's permission pages", () {
    Future<void> open(WidgetTester tester, String project) async {
      await app.pump(tester, ProjectSettingsPage(project: project));
      await tester.scrollUntilVisible(
        find.text("Permissions"),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await settleIo(tester);
      await tester.tap(find.text("Permissions"));
      await settleIo(tester);
    }

    testWidgets("the inherited label names the app-level tier", (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      await open(tester, "research");

      expect(
          find.textContaining("The app's own permissions"), findsOneWidget);
    });

    testWidgets("the writable directories section saves what is added",
        (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      await open(tester, "research");

      expect(find.text("Writable directories"), findsOneWidget);
      await tester.tap(find.text("Add directory"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).last, "/mnt/data");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 10);

      final settings = ProjectSettings.load(app.config, project: "research");
      expect(settings.writableDirs, ["/mnt/data"]);
    });
  });

}
