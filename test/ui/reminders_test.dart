import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/reminders/incoming_open.dart";
import "package:agent_chat/ui/settings/reminders.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/widgets/resettable_field.dart";

import "../fakes.dart";
import "../harness.dart";

/// The field on the prompt page, and not the editor's Name behind it: a route
/// under another is still in the tree, so every finder here is anchored to the
/// page it means.
Finder get _promptField => find.descendant(
      of: find.byType(ReminderPromptPage),
      matching: find.byType(TextField),
    );

Finder _on(Type page, String label) =>
    find.descendant(of: find.byType(page), matching: find.text(label));

/// Write [text] as the reminder's prompt, through the page that edits it.
Future<void> writePrompt(WidgetTester tester, String text) async {
  await scrollTo(tester, find.text("Edit prompt"));
  await tester.tap(find.text("Edit prompt"));
  await settleIo(tester);
  await tester.enterText(_promptField, text);
  await tester.tap(_on(ReminderPromptPage, "Save"));
  await settleIo(tester);
}

void main() {
  testWidgets("a platform with no clock says so and offers nothing",
      (tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.reminders);

    expect(find.textContaining("does not support reminders"), findsOneWidget);
    expect(find.text("Add reminder"), findsNothing);
  });

  testWidgets("lists reminders with their next fire", (tester) async {
    final alarms = FakeReminderAlarms();
    final app = TestApp.create(
      reminderAlarms: alarms,
      reminders: [
        Reminder(
          id: "r1",
          name: "Morning sweep",
          prompt: "check builds",
          at: DateTime.now().add(const Duration(hours: 3)),
          nextFireAt: DateTime.now().add(const Duration(hours: 3)),
          requestCode: 1,
        ),
      ],
    );
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.reminders);

    expect(find.text("Morning sweep"), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text("Add reminder"), findsOneWidget);
  });

  testWidgets("saving an empty prompt is refused", (tester) async {
    final alarms = FakeReminderAlarms();
    final app = TestApp.create(reminderAlarms: alarms);
    addTearDown(app.dispose);
    useWindow(tester, const Size(400, 900));
    await pumpSettings(tester, app, SettingsCategory.reminders);

    await tester.tap(find.text("Add reminder"));
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
    await pumpSettings(tester, app, SettingsCategory.reminders);

    await tester.tap(find.text("Add reminder"));
    await settleIo(tester);

    await writePrompt(tester, "Summarise the workspace");
    await scrollTo(tester, _on(ReminderEditorPage, "Save"));
    await tester.tap(_on(ReminderEditorPage, "Save"));
    await settleIo(tester);

    // The editor closed and the row is there, named by its only text.
    await pumpUntil(tester, find.textContaining("Summarise the workspace"));
    expect(app.container.read(remindersProvider), hasLength(1));
    // The alarm request code was assigned.
    expect(
        app.container.read(remindersProvider).single.requestCode, greaterThanOrEqualTo(1));
  });

  group("the editor", () {
    late TestApp app;

    Future<void> openEditor(WidgetTester tester, {Reminder? reminder}) async {
      app = TestApp.create(
        reminderAlarms: FakeReminderAlarms(),
        reminders: [?reminder],
      );
      addTearDown(app.dispose);
      useWindow(tester, const Size(400, 900));
      await pumpSettings(tester, app, SettingsCategory.reminders);
      await tester.tap(find.text(reminder == null ? "Add reminder" : reminder.name));
      await settleIo(tester);
    }

    Reminder seeded({String prompt = "check builds"}) => Reminder(
          id: "r1",
          name: "Morning sweep",
          prompt: prompt,
          at: DateTime.now().add(const Duration(hours: 3)),
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
      await openEditor(tester, reminder: seeded(prompt: "# Sweep\n\n- builds"));

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

      expect(find.byType(ReminderPromptPage), findsNothing);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        "Summarise **everything**",
      );
    });

    testWidgets("discarding leaves the prompt as it was", (tester) async {
      await openEditor(tester, reminder: seeded());

      await tester.tap(find.text("Edit prompt"));
      await settleIo(tester);
      await tester.enterText(_promptField, "something else entirely");
      await tester.tap(find.byTooltip("Discard"));
      await settleIo(tester);
      await tester.tap(find.text("Discard"));
      await settleIo(tester);

      expect(find.byType(ReminderPromptPage), findsNothing);
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

      await scrollTo(tester, _on(ReminderEditorPage, "Save"));
      await tester.tap(_on(ReminderEditorPage, "Save"));
      await settleIo(tester);

      expect(app.container.read(remindersProvider).single.tempChatTtl,
          TempChatTtl.hours24);
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
      const IncomingReminderOpen(child: Scaffold(body: Text("whatever was up"))),
      settle: false,
    );
    alarms.tap(chat.state.id);
    await pumpUntil(tester, find.text(chat.state.title));
  });
}
