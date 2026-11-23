import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:entoli_core/model/formatting.dart";
import "package:entoli_core/view/widgets/text_file_page.dart";
import "package:entoli_core/view/workspace/workspace_page.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;
  late String root;

  void start({FakeFileHandoff? handoff}) {
    app = TestApp.create(handoff: handoff);
    root = app.config.projectWorkspaceDir();
    Directory(root).createSync(recursive: true);
  }

  tearDown(() => app.dispose());

  void seed({List<String> files = const [], List<String> folders = const []}) {
    for (final folder in folders) {
      Directory("$root/$folder").createSync(recursive: true);
    }
    for (final file in files) {
      File("$root/$file")
        ..createSync(recursive: true)
        ..writeAsStringSync("contents of $file");
    }
  }

  Future<void> open(WidgetTester tester) async {
    await app.pump(tester, WorkspacePage(root: root, title: "Chat workspace"));
    await settleIo(tester);
  }

  Future<void> menu(WidgetTester tester, String entry, String item) async {
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, entry),
        matching: find.byTooltip("More"),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets("a file shows its size, a folder a chevron, folders first", (
    tester,
  ) async {
    start();
    seed(files: ["notes.txt"], folders: ["src"]);
    await open(tester);

    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data);
    expect(titles, ["src", "notes.txt"]);
    expect(find.text(formatSize("contents of notes.txt".length)), findsOne);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets("an empty workspace says so", (tester) async {
    start();
    await open(tester);
    expect(find.text("Nothing here yet"), findsOneWidget);
  });

  testWidgets("a folder opens in place, and back climbs out of it", (
    tester,
  ) async {
    start();
    seed(files: ["src/main.dart"], folders: ["src"]);
    await open(tester);

    await tester.tap(find.text("src"));
    await settleIo(tester);
    expect(find.text("main.dart"), findsOneWidget);
    expect(find.text("src"), findsWidgets);

    await tester.tap(find.byType(BackButton));
    await settleIo(tester);
    expect(find.text("Chat workspace"), findsOneWidget);
    expect(find.byType(WorkspacePage), findsOneWidget);
  });

  testWidgets("a text file opens in the app, anything else is handed off", (
    tester,
  ) async {
    final handoff = FakeFileHandoff();
    start(handoff: handoff);
    seed(files: ["readme.md", "photo.png"]);
    await open(tester);

    await tester.tap(find.text("photo.png"));
    await settleIo(tester);
    expect(handoff.opened, ["$root/photo.png"]);

    await tester.tap(find.text("readme.md"));
    await settleIo(tester);
    expect(find.byType(TextFilePage), findsOneWidget);
  });

  testWidgets("a new folder lands in the folder being looked at", (
    tester,
  ) async {
    start();
    seed(folders: ["src"]);
    await open(tester);
    await tester.tap(find.text("src"));
    await settleIo(tester);

    await tester.tap(find.byTooltip("New folder"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "lib");
    await tester.tap(find.text("Create"));
    await settleIo(tester);

    expect(Directory("$root/src/lib").existsSync(), isTrue);
    expect(find.text("lib"), findsOneWidget);
  });

  testWidgets("deleting an entry asks, and a folder goes with its files", (
    tester,
  ) async {
    start();
    seed(files: ["src/a.txt"], folders: ["src"]);
    await open(tester);

    await menu(tester, "src", "Delete");
    expect(find.text("Delete \"src\"?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Delete"));
    await settleIo(tester);

    expect(Directory("$root/src").existsSync(), isFalse);
    expect(find.text("Nothing here yet"), findsOneWidget);
  });

  testWidgets("a long press selects, and the selection is deleted together", (
    tester,
  ) async {
    start();
    seed(files: ["a.txt", "b.txt", "c.txt"]);
    await open(tester);

    await tester.longPress(find.text("a.txt"));
    await tester.pump();
    await tester.tap(find.text("b.txt"));
    await tester.pump();
    expect(find.text("2 selected"), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    await tester.tap(find.byTooltip("Delete"));
    await tester.pumpAndSettle();
    expect(find.text("Delete 2 items?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "Delete"));
    await settleIo(tester);

    expect(File("$root/a.txt").existsSync(), isFalse);
    expect(File("$root/b.txt").existsSync(), isFalse);
    expect(File("$root/c.txt").existsSync(), isTrue);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets("Cancel ends a selection without touching anything", (
    tester,
  ) async {
    start();
    seed(files: ["a.txt"]);
    await open(tester);

    await tester.tap(find.byTooltip("Select"));
    await tester.pump();
    expect(find.byType(Checkbox), findsOneWidget);
    await tester.tap(find.byTooltip("Cancel selection"));
    await tester.pump();
    expect(find.byType(Checkbox), findsNothing);
    expect(File("$root/a.txt").existsSync(), isTrue);
  });

  testWidgets("a desktop shows the folder being looked at, not the root", (
    tester,
  ) async {
    final handoff = FakeFileHandoff.desktop();
    start(handoff: handoff);
    seed(folders: ["src"]);
    await open(tester);
    await tester.tap(find.text("src"));
    await settleIo(tester);

    await tester.tap(find.byTooltip("Show in File Manager"));
    await settleIo(tester);
    expect(handoff.revealed, ["$root/src"]);
    expect(find.text("Share…"), findsNothing);
  });

  testWidgets("a phone shares an entry, or a selection, and has no file "
      "manager", (tester) async {
    final handoff = FakeFileHandoff.android();
    start(handoff: handoff);
    seed(files: ["a.txt", "b.txt"]);
    await open(tester);
    expect(find.byTooltip("Show in File Manager"), findsNothing);

    await menu(tester, "a.txt", "Share…");
    await settleIo(tester);
    expect(handoff.exported, [
      ["$root/a.txt"],
    ]);

    await tester.longPress(find.text("b.txt"));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await settleIo(tester);
    expect(handoff.exported.last, ["$root/b.txt"]);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets("a folder that will not read says so, and is tried again", (
    tester,
  ) async {
    start();
    Process.runSync("chmod", ["000", root]);
    addTearDown(() => Process.runSync("chmod", ["755", root]));
    await open(tester);
    expect(find.text("That folder could not be read"), findsOneWidget);
    expect(find.byTooltip("New folder"), findsNothing);

    Process.runSync("chmod", ["755", root]);
    await tester.tap(find.text("Try again"));
    await settleIo(tester);
    expect(find.text("Nothing here yet"), findsOneWidget);
    expect(find.byTooltip("New folder"), findsOneWidget);
  });
}
