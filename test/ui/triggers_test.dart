import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/date_words.dart" show describeFire;
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/triggers/incoming_open.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/settings/triggers.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

/// The field on the prompt page, and not the editor's Name behind it: a route
/// under another is still in the tree, so every finder here is anchored to the
/// page it means.
Finder get _promptField => find.descendant(
      of: find.byType(TriggerPromptPage),
      matching: find.byType(TextField),
    );

Finder _on(Type page, String label) =>
    find.descendant(of: find.byType(page), matching: find.text(label));

/// Write [text] as the trigger's prompt, through the page that edits it.
Future<void> writePrompt(WidgetTester tester, String text) async {
  await scrollTo(tester, find.text("Edit prompt"));
  await tester.tap(find.text("Edit prompt"));
  await settleIo(tester);
  await tester.enterText(_promptField, text);
  await tester.tap(_on(TriggerPromptPage, "Save"));
  await settleIo(tester);
}

void main() {
  testWidgets("a platform with no clock does not list the category",
      (tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await app.pump(tester, const SettingsPage());

    expect(tile("Triggers"), findsNothing);
    expect(tile("General"), findsOneWidget);
  });

  testWidgets("the description is the honest one per what the platform can do",
      (tester) async {
    // Linux's answer: notifications over the session bus, nothing to wake
    // the process with. The list works; the description is the honest one.
    final alarms = FakeReminderAlarms(schedulesOverride: false);
    var app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.triggers);

    expect(find.textContaining("caught up at the next launch"), findsOneWidget);
    expect(find.textContaining("even when the app is closed"), findsNothing);
    expect(find.text("Add trigger"), findsOneWidget);

    // One that can fire closed says that instead.
    app.dispose();
    app = TestApp.create(reminderAlarms: FakeReminderAlarms());
    await pumpSettings(tester, app, SettingsCategory.triggers);

    expect(find.textContaining("even when the app is closed"), findsOneWidget);
    expect(find.textContaining("caught up at the next launch"), findsNothing);
  });

  testWidgets("lists reminders with their next fire", (tester) async {
    final alarms = FakeReminderAlarms();
    // A fire far from any clock this suite runs on: far enough that the row's
    // wording is the short date, never today or tomorrow.
    final fires = DateTime(2027, 3, 5, 20, 30);
    final app = TestApp.create(
      reminderAlarms: alarms,
      triggers: [
        Trigger(
          id: "r1",
          name: "Morning sweep",
          prompt: "check builds",
          source: ScheduleSource(at: fires),
          nextFireAt: fires,
          requestCode: 1,
        ),
      ],
    );
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.triggers);

    expect(find.text("Morning sweep"), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text("Add trigger"), findsOneWidget);
    // And the row says when it next fires — the wording the row derives.
    expect(find.textContaining(describeFire(fires, DateTime.now())),
        findsOneWidget);
  });

  testWidgets("a permission granted in the system settings shows on the way back",
      (tester) async {
    final alarms = FakeReminderAlarms()..exact = false;
    final app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.triggers);
    expect(find.text("Exact times are not granted"), findsOneWidget);

    // Granted while the app is behind the system settings, then the app is
    // brought back to the foreground: the page needs to re-read rather than
    // keep what it first asked.
    alarms.exact = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleIo(tester);

    expect(find.text("Exact times are not granted"), findsNothing);
  });

  testWidgets("saving an empty prompt is refused", (tester) async {
    final alarms = FakeReminderAlarms();
    final app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.triggers);

    await tester.tap(find.text("Add trigger"));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text("Save"));
    await tester.tap(find.text("Save"));
    await tester.pump();
    expect(find.textContaining("Write the prompt first."), findsOneWidget);
  });

  testWidgets("a saved reminder is listed and on disk", (tester) async {
    final alarms = FakeReminderAlarms();
    final app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.triggers);

    await tester.tap(find.text("Add trigger"));
    await settleIo(tester);

    await writePrompt(tester, "Summarise the workspace");
    await scrollTo(tester, _on(TriggerEditorPage, "Save"));
    await tester.tap(_on(TriggerEditorPage, "Save"));
    await settleIo(tester);

    // The editor closed and the row is there, named by its only text.
    await pumpUntil(tester, find.textContaining("Summarise the workspace"));
    expect(app.container.read(triggersProvider), hasLength(1));
    // The alarm request code was assigned.
    expect(
        app.container.read(triggersProvider).single.requestCode, greaterThanOrEqualTo(1));
  });

  group("the editor", () {
    late TestApp app;

    /// The member dropdown, found through its row's label — the project
    /// dropdown beside it is the same type.
    Finder memberDropdown() => find.descendant(
          of: find.ancestor(
              of: find.text("Address to"), matching: find.byType(LabelledField)),
          matching: find.byType(DropdownButtonFormField<String?>),
        );

    Future<void> openEditor(WidgetTester tester, {Trigger? trigger}) async {
      app = TestApp.create(
        reminderAlarms: FakeReminderAlarms(),
        triggers: [?trigger],
      );
      addTearDown(app.dispose);
      useWindow(tester, const Size(400, 900));
      await pumpSettings(tester, app, SettingsCategory.triggers);
      await tester.tap(find.text(trigger == null ? "Add trigger" : trigger.name));
      await settleIo(tester);
    }

    Trigger seeded({String prompt = "check builds"}) => Trigger(
          id: "r1",
          name: "Morning sweep",
          prompt: prompt,
          source: ScheduleSource(at: DateTime.now().add(const Duration(hours: 3))),
          nextFireAt: DateTime.now().add(const Duration(hours: 3)),
          requestCode: 1,
        );

    testWidgets("the name is one row and the date and time the next",
        (tester) async {
      await openEditor(tester);

      final name = tester.getRect(find.byType(TextFormField));
      final date = tester.getRect(find.byType(OutlinedButton).at(0));
      final time = tester.getRect(find.byType(OutlinedButton).at(1));

      expect(date.top, greaterThanOrEqualTo(name.bottom));
      expect(date.top, time.top);
    });

    testWidgets("the prompt is shown as the message it will send",
        (tester) async {
      await openEditor(tester, trigger: seeded(prompt: "# Sweep\n\n- builds"));

      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        "# Sweep\n\n- builds",
      );
    });

    testWidgets("with nothing written yet the preview says what goes there",
        (tester) async {
      await openEditor(tester);

      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.text("What should the agent do?"), findsOneWidget);
    });

    testWidgets("what the prompt page saves comes back to the preview",
        (tester) async {
      await openEditor(tester);
      await writePrompt(tester, "Summarise **everything**");

      expect(find.byType(TriggerPromptPage), findsNothing);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        "Summarise **everything**",
      );
    });

    testWidgets("discarding leaves the prompt as it was", (tester) async {
      await openEditor(tester, trigger: seeded());

      await tester.tap(find.text("Edit prompt"));
      await settleIo(tester);
      await tester.enterText(_promptField, "something else entirely");
      await tester.tap(find.byTooltip("Discard"));
      await settleIo(tester);
      await tester.tap(find.text("Discard"));
      await settleIo(tester);

      expect(find.byType(TriggerPromptPage), findsNothing);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        "check builds",
      );
    });

    testWidgets("the prompt page completes a command, the way the composer does",
        (tester) async {
      await openEditor(tester);
      await tester.tap(find.text("Edit prompt"));
      await settleIo(tester);

      await tester.enterText(_promptField, "/rev");
      await settleIo(tester);
      await tester.tap(find.text("/revert"));
      await settleIo(tester);

      expect(tester.widget<TextField>(_promptField).controller?.text, "/revert ");
    });

    testWidgets("the + button opens the agent menu there too", (tester) async {
      await openEditor(tester);
      await tester.tap(find.text("Edit prompt"));
      await settleIo(tester);

      await tester.tap(find.byIcon(Icons.add));
      await settleIo(tester);
      await tester.tap(find.text("Agents"));
      await settleIo(tester);

      expect(find.text("@explore"), findsOneWidget);
    });

    testWidgets("temporary chat is the chat settings combobox, and is saved",
        (tester) async {
      await openEditor(tester);
      await writePrompt(tester, "check builds");
      await scrollTo(tester, find.text("Temporary chat"));

      expect(find.byType(DropdownButtonFormField<TempChatTtl?>), findsOneWidget);
      expect(find.textContaining("$defaultOptionLabel ("), findsWidgets);

      await tester.tap(find.byType(DropdownButtonFormField<TempChatTtl?>));
      await settleIo(tester);
      await tester.tap(find.text("24 hours").last);
      await settleIo(tester);

      await scrollTo(tester, _on(TriggerEditorPage, "Save"));
      await tester.tap(_on(TriggerEditorPage, "Save"));
      await settleIo(tester);

      expect(app.container.read(triggersProvider).single.tempChatTtl,
          TempChatTtl.hours24);
    });

    testWidgets("a member is picked from the library and saved sigil-off",
        (tester) async {
      await openEditor(tester);
      await writePrompt(tester, "triage the bugs");

      await scrollTo(tester, find.text("Address to"));
      await tester.tap(memberDropdown());
      await settleIo(tester);
      await tester.tap(find.text("@explore").last);
      await settleIo(tester);

      await scrollTo(tester, _on(TriggerEditorPage, "Save"));
      await tester.tap(_on(TriggerEditorPage, "Save"));
      await settleIo(tester);

      final stored = app.container.read(triggersProvider).single;
      expect(stored.member, "explore");
    });

    testWidgets("the row names who the fire is addressed to", (tester) async {
      await openEditor(
        tester,
        trigger: seeded().copyWith(member: "explore"),
      );
      await settleIo(tester);

      await pumpUntil(tester, find.textContaining("@explore"));
    });

    testWidgets("a member the library has lost keeps its name and says so",
        (tester) async {
      await openEditor(
        tester,
        trigger: seeded().copyWith(member: "vanished"),
      );
      await settleIo(tester);

      await scrollTo(tester, find.text("Address to"));
      expect(find.text("@vanished (deleted)"), findsOneWidget);
      expect(
          find.textContaining("a fire will reach the whole room"),
          findsOneWidget);

      // Keeping is choosing it again; the stored record is not cleared
      // behind the user's back.
      await tester.tap(memberDropdown());
      await settleIo(tester);
      await tester.tap(find.text("@vanished (deleted)").last);
      await settleIo(tester);
      await scrollTo(tester, _on(TriggerEditorPage, "Save"));
      await tester.tap(_on(TriggerEditorPage, "Save"));
      await settleIo(tester);

      expect(app.container.read(triggersProvider).single.member, "vanished");
    });
  });

  testWidgets("tapping a finished notification opens the chat it ran in",
      (tester) async {
    final alarms = FakeReminderAlarms();
    final app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    final chat = await io(tester, () => app.seedChat());
    // Warm what the claim handler reads: under the fake clock a first read
    // would be real file I/O nobody pumps for.
    await io(tester, () => app.container.read(chatListProvider.future));

    await app.pump(
      tester,
      const IncomingTriggerOpen(child: Scaffold(body: Text("whatever was up"))),
      settle: false,
    );
    alarms.tap(chat.state.id);
    await pumpUntil(tester, find.text(chat.state.title));
  });
}
