import "dart:io";

import "package:flutter/foundation.dart" show debugDefaultTargetPlatformOverride, TargetPlatform;
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:super_sliver_list/super_sliver_list.dart";

import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/plan.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/project.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/omada_separator.dart";
import "package:agent_chat/ui/widgets/agent_picture.dart" show AgentPictureImage;
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/plan_page.dart";
import "package:agent_chat/ui/chat/widgets/chapter_rail.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/view_only_bar.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
import "package:agent_chat/ui/chat/widgets/needs_setup_bar.dart";
import "package:agent_chat/ui/chat/widgets/paired_project_badges.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/theme.dart";

import "../fakes.dart" show onePixelPng;
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// What is in the composer. The text rather than a finder over it: a
  /// `find.text` would match the same words drawn anywhere else on the page.
  /// What the question headline shows mid-sweep: a hybrid, so it matches no
  /// settled question. It is the page's only centred 16pt text — the
  /// composer's hint is left-aligned and its labels smaller.
  String questionShown(WidgetTester tester) =>
      tester.widget<Text>(find.byWidgetPredicate((w) =>
          w is Text &&
          w.data != null &&
          w.style?.fontSize == 16 &&
          w.textAlign == TextAlign.center)).data!;

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
    String Function(int i)? text,
  }) =>
      io(tester, () async {
        final chat = await app.repo.createChat(title: title, project: project);
        final said = [
          for (var i = 0; i < messages; i++)
            Message(
              id: "m$i",
              role: i.isEven ? MessageRole.user : MessageRole.assistant,
              createdAt: DateTime(2026, 1, 1, 0, i),
              parts: [TextPart(text: text?.call(i) ?? "line $i")],
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

    // A paired device's project is a new chat there: the composer and that
    // device's library, and none of what names this device's own models.
    testWidgets("a paired device's project offers a chat there", (tester) async {
      app.dispose();
      app = TestApp.create(remotes: [
        RemoteChatEntry(
          chatId: "r1",
          deviceId: "phone",
          deviceName: "Phone",
          state: ChatState(
              id: "r1",
              title: "On the phone",
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1)),
          online: true,
        ),
      ], remoteProjects: {
        (device: "phone", project: null): RemoteProject(
            ProjectSettings(),
            AppSettings(),
            PromptLibrary([
              PromptDocument(
                  kind: CompletionKind.skill,
                  name: "deploy",
                  frontmatter: const {},
                  body: ""),
            ])),
      });
      app.container
          .read(selectedProjectProvider.notifier)
          .select((device: "phone", project: null));

      await app.pump(tester, const ChatPage(withDrawer: true));

      expect(find.byType(Composer), findsOneWidget);
      expect(find.byTooltip("Chat settings"), findsNothing);
      // This device's badges stay, none ticked, as the way back.
      expect(find.widgetWithText(ChoiceChip, anonProjectLabel), findsWidgets);
      expect(
          tester
              .widgetList<ChoiceChip>(find.byType(ChoiceChip))
              .where((chip) => chip.selected),
          hasLength(1));
      expect(find.widgetWithText(ActionChip, "/deploy"), findsOneWidget);
      expect(app.container.read(selectedChatIdProvider), isNull);
    });

    testWidgets("with that device away there is nothing to send to",
        (tester) async {
      app.container
          .read(selectedProjectProvider.notifier)
          .select((device: "phone", project: null));

      await app.pump(tester, const ChatPage(withDrawer: true));

      expect(find.byType(Composer), findsNothing);
      expect(find.byType(ViewOnlyBar), findsOneWidget);
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

      expect(find.widgetWithText(ChoiceChip, anonProjectLabel), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, myTeamProjectLabel), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, byteRepairProjectLabel), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      // Each built-in's badge carries its icon as the chip's avatar.
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      expect(find.byIcon(Icons.groups), findsOneWidget);
      expect(find.byIcon(Icons.verified_user), findsOneWidget);
    });

    testWidgets("picking the built-in badge moves the chat to it", (tester) async {
      await openEmpty(tester);

      await pick(tester, anonProjectLabel);

      expect(app.container.read(selectedProjectProvider).project, "anonymous");

      await sendMessage(tester, "hello");

      expect(await projectOfMade(tester), "anonymous");
    });

    // Byte Repair requires setup: until the marker is there the bar stands in
    // for the composer, so nothing can be sent into a rootfs that is not
    // there. See "Setup required" in `needs_setup_bar.dart`.
    testWidgets("a project that needs setup stands a bar in for the composer",
        (tester) async {
      await openEmpty(tester);

      await pick(tester, byteRepairProjectLabel);

      expect(find.byType(NeedsSetupBar), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
    });

    // An existing chat in the project is gated the same way — the bar is the
    // whole of the bottom slot there too, not a notice above the composer.
    testWidgets("an open chat in the project is gated too", (tester) async {
      final chat =
          await io(tester, () => app.seedChat(project: "byte-repair"));
      app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(NeedsSetupBar));
      await settleIo(tester);

      expect(find.byType(Composer), findsNothing);
    });

    // The marker alone is not enough on Android: Byte Repair needs a rootfs
    // with a package manager, and "Host" has none — a setup run under a
    // rootfs leaves the marker on disk, so the Host env that follows is what
    // the closing phase of the test below asserts. The `androidTest` wrapper
    // sets the platform override the way `link_opener_test.dart` does, and
    // undoes it before the tear-down.
    void androidTest(String description, Future<void> Function(WidgetTester) body) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    androidTest("a rootfs env on Android lets the composer through with the marker",
        (tester) async {
      app.dispose();
      app = TestApp.create(proot: true, linuxes: const {"alpine"});
      File(app.config.setupCompleteFile(project: ByteRepairProject().dir))
        ..createSync(recursive: true)
        ..writeAsStringSync("done");
      await io(tester, () => app.container
          .read(appSettingsProvider.notifier).setRootfs("alpine"));
      await openEmpty(tester);

      await pick(tester, byteRepairProjectLabel);

      expect(find.byType(Composer), findsOneWidget);
      expect(find.byType(NeedsSetupBar), findsNothing);

      // Switching back to Host puts the bar back without touching the marker.
      await io(tester, () => app.container
          .read(appSettingsProvider.notifier).setRootfs(null));
      await tester.pump();
      await settleIo(tester);

      expect(find.byType(NeedsSetupBar), findsOneWidget);
      expect(find.byType(Composer), findsNothing);
    });

    // The built-in ships its own question, so picking it asks what the chat is.
    testWidgets("picking the built-in asks the question anonymously", (tester) async {
      await openEmpty(tester);

      expect(find.text("What would you like to discuss?"), findsOneWidget);

      await pick(tester, anonProjectLabel);

      expect(find.text("What would you like to discuss anonymously?"), findsOneWidget);
      expect(find.text("What would you like to discuss?"), findsNothing);
    });

    // The question sweeps rather than swaps: the new text takes over from
    // the first character and the change front moves towards the end.
    testWidgets("the question sweeps to the new one progressively",
        (tester) async {
      await openEmpty(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, anonProjectLabel));
      await tester.pump(const Duration(milliseconds: 1));
      // The sweep mounted on that frame; this one runs 350 of the 400ms it
      // takes. The two questions share their first thirty characters, so the
      // front is past where they diverge — and not yet at the end.
      await tester.pump(const Duration(milliseconds: 350));
      final mid = questionShown(tester);
      expect(mid, isNot("What would you like to discuss?"));
      expect(mid, isNot("What would you like to discuss anonymously?"));
      // The front starts at the first character: the new question's opening
      // is already shown.
      expect(mid.startsWith("What would"), isTrue);

      await tester.pumpAndSettle();
      expect(find.text("What would you like to discuss anonymously?"),
          findsOneWidget);
    });

    // The front runs the longer string's length: a shorter new question has
    // to see the old one's tail eaten past the new question's end, not left
    // standing behind the front forever.
    testWidgets("deselecting sweeps the old tail away", (tester) async {
      await openEmpty(tester);

      await pick(tester, anonProjectLabel);
      await tester.pumpAndSettle();
      expect(find.text("What would you like to discuss anonymously?"),
          findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, anonProjectLabel));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 350));

      // The front has eaten past the shorter question's end: what is shown
      // is neither the old long question nor the new short one yet.
      final mid = questionShown(tester);
      expect(mid, isNot("What would you like to discuss anonymously?"));

      await tester.pumpAndSettle();
      expect(find.text("What would you like to discuss?"), findsOneWidget);
      expect(find.textContaining("nonymously"), findsNothing);
    });

    // A user project's description is what the screen asks over its badge:
    // the settings field is the only way a project names its own.
    testWidgets("a project's description asks over its badge", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("work");
        await app.container
            .read(projectSettingsProvider("work").notifier)
            .setDescription("What are we building?");
      });
      await openEmpty(tester);

      expect(find.text("What would you like to discuss?"), findsOneWidget);

      await pick(tester, "work");
      await tester.pumpAndSettle();

      expect(find.text("What are we building?"), findsOneWidget);
      expect(find.text("What would you like to discuss?"), findsNothing);
    });

    // Empty is a value of its own: the screen asks nothing at all, and the
    // reset button is what puts the app-wide question back.
    testWidgets("an empty description asks nothing until reset", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("work");
        await app.container
            .read(projectSettingsProvider("work").notifier)
            .setDescription("");
      });
      await openEmpty(tester);

      await pick(tester, "work");
      await tester.pumpAndSettle();

      expect(find.text("What would you like to discuss?"), findsNothing);
      // The label stays on the tree and swept to empty rather than leaving
      // it, so nothing is what it reads.
      expect(questionShown(tester), "");

      await io(tester, () => app.container
          .read(projectSettingsProvider("work").notifier)
          .setDescription(null));
      await tester.pumpAndSettle();

      expect(find.text("What would you like to discuss?"), findsOneWidget);
    });

    // The badge says where the next chat goes. Nothing selected is the
    // default project, so leaving one is pressing it again.
    testWidgets("picking one highlights it, and pressing it again un-picks it",
        (tester) async {
      await openWithProject(tester);

      await pick(tester, "work");
      expect(selectedOf(tester, "work"), isTrue);
      expect(app.container.read(selectedProjectProvider).project, "work");

      await pick(tester, "work");
      expect(selectedOf(tester, "work"), isFalse);
      expect(app.container.read(selectedProjectProvider).project, isNull);

      await pick(tester, "work");
      await sendMessage(tester, "hello");
      expect(await projectOfMade(tester), "work");
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
        await tester.tap(find.textContaining("Run everything without asking").last);
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

  // The rows below the first view are measured over the frames after it, and
  // the end moves down with them.
  testWidgets("a chat of tall replies opens at its latest message", (tester) async {
    useWindow(tester, const Size(1400, 900));
    final tall = [for (var i = 0; i < 40; i++) "para $i"].join("\n\n");
    final chat = await seedLongChat(tester,
        messages: 6, text: (i) => i.isOdd ? tall : "p$i");

    await open(tester, chat.state.id);

    expect(position(tester).pixels, position(tester).maxScrollExtent);
    expect(find.text("para 39").hitTestable(), findsOneWidget);
  });

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

    await tester.drag(find.byType(SuperListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(AppBar), matching: find.text("at work")),
        findsOneWidget);
    expect(find.text(appTitle), findsNothing);
  });

  // A built-in project's directory name is not what the bar should read; it is
  // labelled the way the menus label it.
  testWidgets("a chat in a built-in project is named by the project's label",
      (tester) async {
    final chat =
        await seedLongChat(tester, title: "off the record", project: "anonymous");

    await open(tester, chat.state.id);

    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text(anonProjectLabel)),
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
    // Every chat is in a project, so naming the default says nothing.
    expect(find.text("Default"), findsNothing);
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

  // The project and the countdown share a line: the project at its left, the
  // countdown held to the right edge.
  testWidgets("a chat that is both in a project and temporary has one detail line",
      (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "at work", project: "work"));
    await io(tester, () => app.makeTemporary(chat.state));

    await open(tester, chat.state.id);

    final bar = find.byType(AppBar);
    final project = find.descendant(of: bar, matching: find.text("work"));
    final hourglass =
        find.descendant(of: bar, matching: find.byIcon(Icons.hourglass_empty));
    expect(project, findsOneWidget);
    expect(hourglass, findsOneWidget);
    expect(tester.getCenter(project).dy,
        moreOrLessEquals(tester.getCenter(hourglass).dy, epsilon: 1));
    final middle = tester.getCenter(bar).dx;
    expect(tester.getCenter(project).dx, lessThan(middle));
    expect(tester.getCenter(hourglass).dx, greaterThan(middle));
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

    testWidgets("picking one types it, and does not reach for the keyboard",
        (tester) async {
      await openBlank(tester);
      // The composer's menus are the only other place these are named.
      expect(find.text("@explore"), findsOneWidget);

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

    // Everything the user has written is a menu, and `/` opens the menu. The
    // screen scrolls, so nothing is held back to keep the page short.
    testWidgets("offers every command there is, not a handful of them",
        (tester) async {
      app.dispose();
      app = TestApp.create(
        library: PromptLibrary([
          for (var i = 0; i < 12; i++)
            PromptDocument.parse(CompletionKind.skill, "cmd$i", "do $i"),
        ]),
      );
      await openBlank(tester);

      expect(find.byType(ActionChip), findsNWidgets(12));
    });

    // A change of set animates per chip: what stays keeps its slot, what
    // arrives grows out of nothing, what leaves shrinks away before going.
    // Driving the library rather than a different TestApp: the swap has to
    // happen under a screen that is already open, which is the case the
    // animation exists for.
    group("a swap of the starter set", () {
      testWidgets("a leaving chip shrinks away before it goes", (tester) async {
        await openBlank(tester);
        await io(tester, () => writeSkill(app, "review"));
        await reloadLibrary(tester, app);
        expect(find.text("/review"), findsOneWidget);

        await io(tester, () async {
          await Directory(
                  "${app.config.promptsDir(CompletionKind.skill)}/review")
              .delete(recursive: true);
        });
        // Reloaded without settling, so the shrink has not been pumped
        // through yet and the chip is still on screen for it.
        await reloadLibrary(tester, app, settle: false);
        await tester.pump();

        // Still shrinking: the chip is held on screen for the animation, and
        // is gone once it has run.
        expect(find.text("/review"), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.text("/review"), findsNothing);
      });

      testWidgets("a project switch keeps what both share and grows in the rest",
          (tester) async {
        // The default's set is what a project without its own inherits, so a
        // switch to a project with one extra skill is the both-motions case:
        // everything shared keeps its slot, the extra grows out of nothing.
        // Both skills are written to disk and both libraries reloaded, since
        // a reload reads the real sources rather than the test's seed.
        await io(tester, () async {
          await app.repo.createProject("work");
          await writeSkill(app, "review");
          await writeSkill(app, "extra", project: "work");
        });
        await openBlank(tester);
        await reloadLibrary(tester, app);
        await reloadLibrary(tester, app, project: "work");
        expect(find.text("/review"), findsOneWidget);

        await tester.tap(find.widgetWithText(ChoiceChip, "work"));
        await tester.pump();

        // Arrived mid-growth beside the chips that never left.
        expect(find.text("/extra"), findsOneWidget);
        expect(find.text("/review"), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.text("/extra"), findsOneWidget);
      });
    });
  });

  group("the conversation", () {
    /// A chat whose turn openers carry the Omada modes of a mixed history:
    /// direct, then on, then off. Written the way the controller would have.
    Future<String> seedSectionedChat(WidgetTester tester) => io(tester, () async {
          final at = DateTime(2026, 1, 1, 12);
          final said = [
            Message(
                id: "u1",
                role: MessageRole.user,
                createdAt: at,
                parts: const [TextPart(text: "first")],
                omadaOn: false),
            Message(id: "a1", role: MessageRole.assistant, createdAt: at),
            Message(
                id: "u2",
                role: MessageRole.user,
                createdAt: at,
                parts: const [TextPart(text: "second")],
                omadaOn: true),
            Message(id: "a2", role: MessageRole.assistant, createdAt: at),
            Message(
                id: "u3",
                role: MessageRole.user,
                createdAt: at,
                parts: const [TextPart(text: "third")],
                omadaOn: false),
            Message(id: "a3", role: MessageRole.assistant, createdAt: at),
          ];
          final chat = await app.repo.createChat();
          await app.writeChat(chat.copyWith(messages: said));
          return chat.state.id;
        });

    testWidgets("both flips draw their separators, and bubbles keep their side",
        (tester) async {
      // Wide enough that "right side" is unambiguous.
      useWindow(tester, const Size(1000, 800));
      final id = await seedSectionedChat(tester);
      await open(tester, id);

      expect(find.text("Omada is turned on"), findsOneWidget);
      expect(find.text("Omada is turned off"), findsOneWidget);
      expect(find.byType(ConversationSeparator), findsNWidgets(2));
      // Both user bubbles end at the same right edge either side of the
      // separator, near the column's edge rather than mid-column.
      final first = tester.getRect(find.text("first")).right;
      final second = tester.getRect(find.text("second")).right;
      expect((first - second).abs(), lessThan(2));
      expect(second, greaterThan(500));
    });

  });

  group("the chapter rail", () {
    testWidgets("is beside the column where there is room, and the column stays put",
        (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      expect(find.byType(ChapterRail), findsOneWidget);
      // A tick per prompt: forty messages, every other one the user's.
      expect(find.byTooltip("line 0"), findsOneWidget);
      expect(find.byTooltip("line 38"), findsOneWidget);
      expect(find.byTooltip("line 1"), findsNothing);
      // Laid over the margin, not beside the column: the column is centred.
      expect(tester.getCenter(find.byType(Composer)).dx, closeTo(700, 1));
      expect(tester.getRect(find.byType(ChapterRail)).left,
          greaterThan(tester.getRect(find.byType(Composer)).right));
    });

    testWidgets("an existing chat with one prompt has its tick on open", (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester, messages: 2);
      await open(tester, chat.state.id);

      expect(find.byTooltip("line 0"), findsOneWidget);
    });

    testWidgets("is gone where the margin has no room for it", (tester) async {
      useWindow(tester, const Size(850, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      expect(find.byType(ChapterRail), findsNothing);
    });

    testWidgets("follows the conversation: a turn adds a tick, a deletion takes it",
        (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      final controller = app.container.read(chatControllerProvider(chat.state.id).notifier);

      app.backend.scriptedEvents = [const TextDelta("sure"), const DoneEvent()];
      await io(tester, () => controller.send("a new prompt"));
      await settleIo(tester);

      expect(find.byTooltip("a new prompt"), findsOneWidget);

      await io(tester, () => controller.deleteThread("m38"));
      await settleIo(tester);

      expect(find.byTooltip("line 38"), findsNothing);
      expect(find.byTooltip("a new prompt"), findsNothing);
      expect(find.byTooltip("line 36"), findsOneWidget);
    });

    testWidgets("is the open chat's, when another is opened", (tester) async {
      useWindow(tester, const Size(1400, 900));
      final first = await seedLongChat(tester);
      final second = await io(tester, () async {
        final chat = await app.repo.createChat(title: "other");
        final full = chat.copyWith(messages: [
          for (final (i, text) in ["elsewhere", "and again"].indexed)
            Message(
              id: "o$i",
              role: MessageRole.user,
              createdAt: DateTime(2026, 2, 1, 0, i),
              parts: [TextPart(text: text)],
            ),
        ]);
        await app.writeChat(full);
        return full;
      });
      await open(tester, first.state.id);
      expect(find.byTooltip("line 0"), findsOneWidget);

      app.container.read(selectedChatIdProvider.notifier).select(second.state.id);
      await pumpUntil(tester, find.byTooltip("elsewhere"));

      expect(find.byTooltip("line 0"), findsNothing);
      expect(find.byTooltip("and again"), findsOneWidget);
    });

    testWidgets("a tick takes the view to its prompt", (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      expect(find.text("line 0"), findsNothing);

      await tester.tap(find.byTooltip("line 0"));
      await tester.pumpAndSettle();

      expect(find.text("line 0"), findsOneWidget);
    });

    testWidgets("a steer has its tick, and it takes the view into the reply",
        (tester) async {
      useWindow(tester, const Size(1400, 900));
      final tall = [for (var i = 0; i < 60; i++) "para $i"].join("\n\n");
      final chat = await io(tester, () async {
        final chat = await app.repo.createChat(title: "steered");
        final full = chat.copyWith(messages: [
          Message(
              id: "u0",
              role: MessageRole.user,
              createdAt: DateTime(2026, 1, 1),
              parts: const [TextPart(text: "start")]),
          Message(
              id: "a0",
              role: MessageRole.assistant,
              createdAt: DateTime(2026, 1, 1, 0, 1),
              parts: [
                TextPart(text: tall),
                MessagePart.steer(
                    message: Message(
                        id: "s0",
                        role: MessageRole.user,
                        createdAt: DateTime(2026, 1, 1, 0, 2),
                        parts: const [TextPart(text: "steer here")])),
                TextPart(text: tall),
              ]),
        ]);
        await app.writeChat(full);
        return full;
      });
      await open(tester, chat.state.id);
      await tester.drag(find.byType(SuperListView), const Offset(0, -100000));
      await tester.pumpAndSettle();
      expect(find.text("steer here").hitTestable(), findsNothing);

      await tester.tap(find.byTooltip("steer here"));
      // Once it has arrived it stays.
      final seen = <double>[];
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(position(tester).pixels);
      }
      await tester.pumpAndSettle();
      final end = position(tester).pixels;
      final arrived = seen.indexWhere((p) => (p - end).abs() < 1);
      expect(arrived, isNot(-1));
      for (final p in seen.skip(arrived)) {
        expect(p, closeTo(end, 1));
      }

      final top = tester.getTopLeft(find.text("steer here")).dy;
      expect(top, inInclusiveRange(0, 200));
    });

    // It used to jump to a guess at an unbuilt prompt first, which could be
    // below the view, and animate up from there.
    testWidgets("a tick above the view only ever scrolls up", (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      var last = position(tester).pixels;
      await tester.tap(find.byTooltip("line 10"));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(position(tester).pixels, lessThanOrEqualTo(last + 0.5));
        last = position(tester).pixels;
      }
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text("line 10")).dy,
          lessThan(tester.getTopLeft(find.text("line 12")).dy));
      expect(find.text("line 10").hitTestable(), findsOneWidget);
    });

    // A row laid out at a height other than the one measured for it moves the
    // view under the glide, which is to carry on from there.
    testWidgets("a glide carries a correction the list makes under it",
        (tester) async {
      useWindow(tester, const Size(1400, 900));
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      await tester.tap(find.byTooltip("line 10"));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final before = position(tester).pixels;
      await tester.pump(const Duration(milliseconds: 16));
      final step = position(tester).pixels - before;
      position(tester).correctBy(300);
      final corrected = position(tester).pixels;
      await tester.pump(const Duration(milliseconds: 16));
      final next = position(tester).pixels - corrected;

      expect(step, lessThan(0));
      // Unfixed it is the step less the 300 put back.
      expect(next, inInclusiveRange(step * 3, 0));
    });
  });

  group("keeping up with a turn", () {
    Future<void> replyArrives(WidgetTester tester, String id) async {
      app.backend.scriptedEvents = [const TextDelta("and another thing"), const DoneEvent()];
      await io(tester,
          () => app.container.read(chatControllerProvider(id).notifier).send("more"));
      await settleIo(tester);
    }

    testWidgets("scrolling back offers the way down again", (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);

      // In view of the end: nothing to jump for yet.
      expect(find.byTooltip("Jump to latest"), findsNothing);

      await tester.drag(find.byType(SuperListView), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(find.byTooltip("Jump to latest"), findsOneWidget);

      await tester.tap(find.byTooltip("Jump to latest"));
      await tester.pumpAndSettle();

      expect(position(tester).pixels, position(tester).maxScrollExtent);
      expect(find.byTooltip("Jump to latest"), findsNothing);
    });

    // The drag that detaches is often inside the follow slack, where the old
    // position test kept handing the view back to the end and the reader
    // could not get away. A gesture is the whole of what counts now.
    testWidgets("a small drag away stays put while a reply arrives", (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      final end = position(tester).maxScrollExtent;
      final held = end - 300;
      await tester.drag(find.byType(SuperListView), Offset(0, end - held));
      await tester.pumpAndSettle();

      await replyArrives(tester, chat.state.id);

      expect(position(tester).pixels, held);
      expect(find.byTooltip("Jump to latest"), findsOneWidget);
    });

    testWidgets("dragging back down re-attaches the follow", (tester) async {
      final chat = await seedLongChat(tester);
      await open(tester, chat.state.id);
      await tester.drag(find.byType(SuperListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.byTooltip("Jump to latest"), findsOneWidget);

      // A fling rather than a drag: a drag lands wherever the finger stops,
      // and the extent it lands short of is still an estimate. A fling's
      // ballistic settle runs to the actual end, which is the gesture that
      // says "take me back".
      await tester.fling(find.byType(SuperListView), const Offset(0, -800), 4000);
      await tester.pumpAndSettle();
      expect(find.byTooltip("Jump to latest"), findsNothing);

      await replyArrives(tester, chat.state.id);

      expect(position(tester).pixels, position(tester).maxScrollExtent);
    });
  });

  group("a turn that never finished", () {
    testWidgets("is offered to be carried on, and the offer goes once taken",
        (tester) async {
      // A finished one is not: the same two messages, a turnEnd on the reply.
      final closed = await seedLongChat(tester, messages: 2);
      await open(tester, closed.state.id);
      expect(find.text("Continue"), findsNothing);

      final chat = await seedLongChat(tester, messages: 2, finished: false);
      await open(tester, chat.state.id);
      expect(find.textContaining("Unfinished turn"), findsOneWidget);

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

  group("the paired devices' badges", () {
    // What the welcome of a paired device named, as the hub would hold it.
    RemoteChatEntry mirrorOf(
      String deviceId,
      String deviceName,
      ChatState state, {
      bool online = true,
      bool omada = false,
    }) =>
        RemoteChatEntry(
          chatId: state.id,
          deviceId: deviceId,
          deviceName: deviceName,
          state: state,
          online: online,
          omada: omada,
        );

    Future<void> openNew(WidgetTester tester) async {
      await app.pump(tester, const ChatPage(withDrawer: true), settle: false);
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);
    }

    Future<void> openEmpty(WidgetTester tester, List<RemoteChatEntry> remotes) {
      app.dispose();
      app = TestApp.create(remotes: remotes);
      return openNew(tester);
    }

    // A device's badges, as against this device's own and the page's
    // `/`-`@` chips.
    Finder deviceChip(String label) => find.descendant(
        of: find.byType(PairedProjectBadges),
        matching: find.widgetWithText(ChoiceChip, label));

    List<String> lines(WidgetTester tester) => [
          for (final line in tester.widgetList<ConversationSeparator>(
              find.byType(ConversationSeparator)))
            line.text,
        ];

    testWidgets("each paired device is a line naming it over its projects",
        (tester) async {
      // Seeded so arrival order differs from name order.
      await openEmpty(tester, [
        mirrorOf("d2", "Phone", makeState("r3"), online: false),
        mirrorOf("d1", "Desktop", makeState("r1")),
        mirrorOf("d1", "Desktop", makeState("r2", project: "work")),
      ]);

      expect(lines(tester), ["Desktop", "Phone · offline"]);
      expect(deviceChip("work"), findsOneWidget);
      // A device's default is a project there, not nothing selected.
      expect(deviceChip("Default"), findsNWidgets(2));
    });

    testWidgets("a badge is styled by Omada on the device, not here",
        (tester) async {
      await openEmpty(tester, [
        mirrorOf("d1", "Desktop", makeState("r1", project: "work"),
            omada: true),
        mirrorOf("d1", "Desktop", makeState("r2", project: "play")),
      ]);

      FontStyle? style(String label) =>
          tester.widget<Text>(find.text(label)).style?.fontStyle;
      expect(style("work"), FontStyle.italic);
      expect(style("play"), isNot(FontStyle.italic));
    });

    testWidgets("a chat that exists with nothing said in it draws none",
        (tester) async {
      // The second caller of `_EmptyChat`: an existing chat, mid-turn at
      // worst. A list of other devices under its question would say nothing
      // true about it, which is why the badges are the new-chat screen's own.
      app.dispose();
      app = TestApp.create(remotes: [
        mirrorOf("d1", "Desktop", makeState("r1")),
      ]);
      final chat = await io(tester, () => app.seedChat(title: "fresh"));
      app.container
          .read(selectedChatIdProvider.notifier)
          .select(chat.state.id);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);

      expect(find.byType(PairedProjectBadges), findsNothing);
      expect(find.text("Desktop"), findsNothing);
    });

    testWidgets("with no device paired there is no line", (tester) async {
      await openEmpty(tester, []);

      expect(find.byType(ConversationSeparator), findsNothing);
    });

    testWidgets("ticking a device's project picks it, and this device's badges "
        "stay to go back with", (tester) async {
      await openEmpty(tester, [
        mirrorOf("d1", "Desktop", makeState("r1", project: "work")),
      ]);

      await tester.tap(deviceChip("work"));
      await tester.pumpAndSettle();
      expect(app.container.read(selectedProjectProvider),
          (device: "d1", project: "work"));
      expect(tester.widget<ChoiceChip>(deviceChip("work")).selected, isTrue);
      expect(app.container.read(selectedChatIdProvider), isNull);

      // Unticked, it is this device's default again.
      await tester.tap(deviceChip("work"));
      await tester.pumpAndSettle();
      expect(app.container.read(selectedProjectProvider), localProject(null));

      // And from a device's project, this device's own badge brings it back.
      await tester.tap(deviceChip("work"));
      await tester.pumpAndSettle();
      final local = find.widgetWithText(ChoiceChip, anonProjectLabel).first;
      expect(tester.widget<ChoiceChip>(local).selected, isFalse);
      await tester.tap(local);
      await tester.pumpAndSettle();
      expect(app.container.read(selectedProjectProvider).device, isNull);
      expect(tester.widget<ChoiceChip>(deviceChip("work")).selected, isFalse);
    });
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

  group("a compaction in the conversation", () {
    testWidgets("the summary is rendered beneath the divider, without a tap",
        (tester) async {
      // A finished chat holding one exchange and a compaction marker of its
      // own — written the way the real turn writes one: a record on the log,
      // not a part of anything.
      final at = DateTime.now();
      final prompt = Message(
          id: "m1", role: MessageRole.user, createdAt: at,
          parts: const [MessagePart.text(text: "hello")]);
      final reply = Message(
          id: "m2",
          role: MessageRole.assistant,
          createdAt: at,
          parts: const [MessagePart.text(text: "hi")]);
      final chat = await io(tester, () async {
        final state = makeState("compacted");
        await app.repo.saveState(state);
        await app.repo.append(state.id, [
          ...recordsOf([prompt, reply]),
          ChatRecord.turnEnd(messageId: "m2", reason: TurnEnd.done),
          const ChatRecord.compaction(
              upToMessageId: "m2", summary: "The user said hello."),
        ]);
        return app.repo.openChat(state.id);
      });
      await open(tester, chat.state.id);

      // The divider is there, and the summary text with it — always visible,
      // not behind a tap.
      expect(find.byType(ConversationSeparator), findsOneWidget);
      expect(find.text("Compact Conversation"), findsOneWidget);
      expect(find.textContaining("The user said hello."), findsOneWidget);
      // Rendered as a reply is: the AI text widget, not a sheet's content.
      expect(
          find.byWidgetPredicate(
              (w) => w is MessageText && w.text.contains("The user said hello.")),
          findsOneWidget);
    });
  });

  group("an addressed member's picture", () {
    // An Omada-on section whose reply names the member it answers — what
    // `MessageBubble.author` draws — with the member's picture seeded beside
    // its `.md`. Written the way the controller stamps a round of them.
    Future<String> seedOmadaChat(WidgetTester tester,
        {required String member, String? project, bool omada = true}) =>
        io(tester, () async {
          final at = DateTime(2026, 1, 1, 12);
          final said = [
            Message(
                id: "u1",
                role: MessageRole.user,
                createdAt: at,
                parts: [TextPart(text: '@$member look into it')],
                documents: {"@$member": "their prompt"},
                omadaOn: omada),
            Message(
                id: "a1",
                role: MessageRole.assistant,
                createdAt: at,
                parts: const [TextPart(text: "Looking.")],
                author: "@$member"),
          ];
          final chat = await app.repo.createChat(project: project ?? "work");
          await app.writeChat(chat.copyWith(messages: said));
          return chat.state.id;
        });

    testWidgets("a member with a picture has it beside their name", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent, project: "work");
      File("$dir/scout.md").createSync(recursive: true);
      File("$dir/scout.md").writeAsStringSync(
          "---\ndescription: the scout\n---\n\nYou look ahead.\n");
      File("$dir/scout.png").writeAsBytesSync(onePixelPng);

      final id = await seedOmadaChat(tester, member: "scout", project: "work");
      await open(tester, id);

      expect(find.text("@scout"), findsOneWidget);
      final avatar = find.descendant(
          of: find.byType(MessageBubble), matching: find.byType(Image));
      expect(avatar, findsOneWidget);
      // `cacheWidth` wraps the provider in a ResizeImage; underneath it is
      // the memory image of the bytes the test seeded.
      final inner = (tester.widget<Image>(avatar).image as ResizeImage)
          .imageProvider as MemoryImage;
      expect(inner.bytes, onePixelPng);
    });

    testWidgets("a member with no picture, and the main agent's reply, name "
        "themselves alone", (tester) async {
      final id = await seedOmadaChat(tester, member: "scout", project: "work");
      await open(tester, id);

      expect(find.text("@scout"), findsOneWidget);
      expect(find.byType(AgentPictureImage), findsNothing);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets("a stamp in a direct chat's history shows its name and picture "
        "the same", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      File("$dir/scout.md").createSync(recursive: true);
      File("$dir/scout.md").writeAsStringSync(
          "---\ndescription: the scout\n---\n\nYou look ahead.\n");
      File("$dir/scout.png").writeAsBytesSync(onePixelPng);

      final id = await seedOmadaChat(tester, member: "scout", omada: false);
      await open(tester, id);

      // A stamp already on the record is fact, wherever Omada now stands:
      // the label shows in a direct chat's section too, and the picture —
      // read against this chat's project, the default one here — with it.
      expect(find.text("@scout"), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });


  // The plan the agent presented is drawn in the conversation, each task
  // opening to its details, and the bar carries a way to it for as long as
  // the chat has one.
  testWidgets("a presented plan shows its tasks, their details, and a page", (tester) async {
    final chat = await io(tester, () async {
      final chat = await app.repo.createChat(title: "planned");
      final full = chat.copyWith(messages: [
        Message(
          id: "u1",
          role: MessageRole.user,
          createdAt: DateTime(2026, 1, 1),
          parts: [const TextPart(text: "fix it")],
        ),
        Message(
          id: "a1",
          role: MessageRole.assistant,
          createdAt: DateTime(2026, 1, 1, 0, 1),
          parts: [
            const ToolCallPart(
                toolCall: ToolCall(
                    id: "pp-1",
                    name: presentPlanToolName,
                    argumentsJson: '{"title": "The fix"}')),
            ToolResultPart(
                result: ToolResult(
                    callId: "pp-1", returnCode: 0, output: planVerdict("go"))),
          ],
        ),
      ]);
      await app.writeChat(full);
      final workspace = app.config.workspaceDir(chat.state.id);
      await app.config.fs.directory(workspace).create(recursive: true);
      await app.config.fs
          .file(app.config.fs.path.join(workspace, planFileName))
          .writeAsString("# Plan\n\n## Tasks\n\n- [x] read the parser\n"
              "  Start at `parse.dart`.\n- [ ] fix the header\n  Keep the old entry point.\n");
      return full;
    });

    await open(tester, chat.state.id);

    expect(find.text("The fix"), findsOneWidget);
    expect(find.text("1 of 2 tasks done"), findsOneWidget);
    // As wide as the reply it sits in, less the gutter the reply's text keeps.
    final bubble = find.byType(MessageBubble).last;
    expect(
        tester.getSize(find.descendant(of: bubble, matching: find.byType(Card))).width,
        greaterThanOrEqualTo(tester.getSize(bubble).width - 24));
    expect(find.text("Keep the old entry point."), findsNothing);
    await tester.tap(find.text("2. fix the header"));
    await settleIo(tester);
    expect(find.text("Keep the old entry point."), findsOneWidget);

    final button =
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.checklist));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settleIo(tester);
    expect(find.byType(PlanPage), findsOneWidget);
    expect(find.descendant(of: find.byType(PlanPage), matching: find.text("1. read the parser")),
        findsOneWidget);
  });

  testWidgets("a chat with no plan has no plan button", (tester) async {
    final chat = await seedLongChat(tester, title: "unplanned");
    await open(tester, chat.state.id);
    expect(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.checklist)),
        findsNothing);
  });

}
