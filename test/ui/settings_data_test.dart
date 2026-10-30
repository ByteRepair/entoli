import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/domain/models.dart";

import "../fakes.dart";
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> openData(WidgetTester tester) =>
      pumpSettings(tester, app, SettingsCategory.data);

  /// Whole-data-directory I/O outlasts the default cap of real rounds — see
  /// `test/AGENTS.md`.
  Future<void> settle(WidgetTester tester) =>
      settleIo(tester, least: 20, tries: 200);

  /// The button's own label rather than the button: `.icon` builds a private
  /// subclass, so `find.byType` has nothing to match on.
  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await settle(tester);
  }

  /// The chats a restarted app would find, read through a store of their own:
  /// the one the page holds was built before the restore and caches which
  /// project each chat is in, which is what the restart replaces.
  Future<List<ChatState>> onDisk(WidgetTester tester) =>
      io(tester, () => FileChatStore(app.config).list());

  /// A backup of everything on disk right now, made the way Export makes one,
  /// somewhere outside the data directory.
  Future<String> exported(WidgetTester tester) => io(tester, () async {
        final path = "${tempDir().path}/backup.zip";
        await writeBackup(app.config, path);
        return path;
      });

  /// A chat in the backup, another added since, and the confirmation up.
  Future<void> offerRestore(WidgetTester tester) async {
    await io(tester, () => app.seedChat(title: "in the backup"));
    app.backups.scripted = await exported(tester);
    await io(tester, () => app.seedChat(title: "added since"));
    await openData(tester);
    await press(tester, "Import");
  }

  testWidgets("Export hands the whole data directory over as a zip", (tester) async {
    await io(tester, () => app.seedChat(title: "kept"));
    await openData(tester);

    await press(tester, "Export");

    expect(app.backups.saved, hasLength(1));
    expect(app.backups.saved.single.name, endsWith(".zip"));
    final backup =
        await io(tester, () => openBackup(app.backups.saved.single.path));
    addTearDown(backup.close);
    expect(backup.chats, 1);
    expect(backup.entries.map((e) => e.name), contains(endsWith("state.json")));
  });

  testWidgets("Import asks before it replaces anything", (tester) async {
    await offerRestore(tester);

    expect(find.text("Restore this backup?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Cancel"));
    await settle(tester);

    expect(await onDisk(tester), hasLength(2));
    expect(app.restart.restarts, 0);
  });

  testWidgets("and replaces them once it has been told to", (tester) async {
    await offerRestore(tester);

    await tester.tap(find.widgetWithText(TextButton, "Restore"));
    await settle(tester);

    expect((await onDisk(tester)).map((c) => c.title), ["in the backup"]);
  });

  // Everything the app read out of the data directory at startup is a restore
  // behind it, and rebuilding is what puts that right rather than a list of
  // things to invalidate.
  testWidgets("and then builds the app again", (tester) async {
    app.backups.scripted = await exported(tester);
    await openData(tester);

    await press(tester, "Import");
    await tester.tap(find.widgetWithText(TextButton, "Restore"));
    await settle(tester);

    expect(app.restart.restarts, 1);
  });

  testWidgets("a file that is not a backup is refused, and nothing is lost",
      (tester) async {
    await io(tester, () => app.seedChat(title: "still here"));
    final notBackup = File("${tempDir().path}/backup.zip")
      ..writeAsStringSync("not a backup");
    app.backups.scripted = notBackup.path;
    await openData(tester);

    await press(tester, "Import");

    expect(find.text("Restore this backup?"), findsNothing);
    expect(find.textContaining("cannot be restored"), findsOneWidget);
    expect(await onDisk(tester), hasLength(1));
    expect(app.restart.restarts, 0);
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

    expect((await onDisk(tester)).single.title, "with a file");
    final resources = Directory(app.config.resourcesDir(chat.state.id));
    expect(resources.listSync(), hasLength(1));
    expect((resources.listSync().single as File).readAsBytesSync(), onePixelPng);
  });
}
