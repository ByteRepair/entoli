import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reminder.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/reminders/incoming_open.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../fakes.dart";
import "../harness.dart";

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

    await tester.enterText(find.widgetWithText(TextField, "Prompt").first,
        "Summarise the workspace");
    await scrollTo(tester, find.text("Save"));
    await tester.tap(find.text("Save"));
    await settleIo(tester);

    // The editor closed and the row is there, named by its only text.
    await pumpUntil(tester, find.textContaining("Summarise the workspace"));
    expect(app.container.read(remindersProvider), hasLength(1));
    // The alarm request code was assigned.
    expect(
        app.container.read(remindersProvider).single.requestCode, greaterThanOrEqualTo(1));
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
