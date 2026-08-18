import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/backup.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> openData(WidgetTester tester) =>
      pumpSettings(tester, app, SettingsCategory.data);

  /// Reading and writing the whole data directory takes longer than the
  /// default cap of real rounds allows, and the busy bar animates until it is
  /// done — so a run that gave up early would land on `pumpAndSettle` with a
  /// running animation and time out.
  Future<void> settle(WidgetTester tester) =>
      settleIo(tester, least: 20, tries: 200);

  /// The button's own label rather than the button: `.icon` builds a private
  /// subclass, so `find.byType` has nothing to match on.
  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
  }

  /// A backup of everything the app has on disk right now, made the way Export
  /// makes one.
  Future<Uint8List> exported(WidgetTester tester) =>
      io(tester, () => app.repo.exportBackup());

  testWidgets("Export hands the whole data directory over as a zip", (tester) async {
    await io(tester, () => app.seedChat(title: "kept"));
    await openData(tester);

    await press(tester, "Export");

    expect(app.backups.saved, hasLength(1));
    expect(app.backups.saved.single.name, endsWith(".zip"));
    final backup = parseBackup(app.backups.saved.single.bytes);
    expect(backup.chats, 1);
    expect(backup.entries.map((e) => e.name), contains(endsWith("state.json")));
  });

  testWidgets("Import asks before it replaces anything", (tester) async {
    await io(tester, () => app.seedChat(title: "in the backup"));
    app.backups.scripted = await exported(tester);
    await io(tester, () => app.seedChat(title: "added since"));
    await openData(tester);

    await press(tester, "Import");

    expect(find.text("Restore this backup?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Cancel"));
    await settle(tester);

    expect(await io(tester, () => app.repo.listChats()), hasLength(2));
  });

  testWidgets("and replaces them once it has been told to", (tester) async {
    await io(tester, () => app.seedChat(title: "in the backup"));
    app.backups.scripted = await exported(tester);
    final since = await io(tester, () => app.seedChat(title: "added since"));
    app.container.read(selectedChatIdProvider.notifier).select(since.state.id);
    await openData(tester);

    await press(tester, "Import");
    await tester.tap(find.widgetWithText(TextButton, "Restore"));
    await settle(tester);

    final chats = await io(tester, () => app.repo.listChats());
    expect(chats.map((c) => c.title), ["in the backup"]);
    // The chat that was open is not in the restored conversation list.
    expect(app.container.read(selectedChatIdProvider), isNull);
  });

  testWidgets("a file that is not a backup is refused, and nothing is lost",
      (tester) async {
    await io(tester, () => app.seedChat(title: "still here"));
    app.backups.scripted = Uint8List.fromList("not a backup".codeUnits);
    await openData(tester);

    await press(tester, "Import");

    expect(find.text("Restore this backup?"), findsNothing);
    expect(find.textContaining("cannot be restored"), findsOneWidget);
    expect(await io(tester, () => app.repo.listChats()), hasLength(1));
  });

  // A turn appends to the log of a chat a restore is about to delete, and it
  // would carry on appending afterwards.
  testWidgets("a running turn is refused rather than restored over", (tester) async {
    app.backend.runningTurns.value = {"busy"};
    app.backups.scripted = await exported(tester);
    await openData(tester);

    await press(tester, "Import");

    expect(find.textContaining("Stop it first"), findsOneWidget);
    expect(app.backups.scripted, isNotNull);
    expect(find.text("Restore this backup?"), findsNothing);
  });

  testWidgets("a restored chat is readable, attachments and all", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "with a file"));
    await io(tester, () async {
      final resource = await app.store.saveResource(
          chat.state.id, "pic.png", Uint8List.fromList(onePixelPng));
      expect(resource, isNotEmpty);
    });
    app.backups.scripted = await exported(tester);
    await io(tester, () => app.repo.deleteAllChats());
    await openData(tester);

    await press(tester, "Import");
    await tester.tap(find.widgetWithText(TextButton, "Restore"));
    await settle(tester);

    final restored = await io(tester, () => app.repo.listChats());
    expect(restored.single.title, "with a file");
    final resources = Directory(app.config.resourcesDir(chat.state.id));
    expect(resources.listSync(), hasLength(1));
    expect((resources.listSync().single as File).readAsBytesSync(), onePixelPng);
  });
}
