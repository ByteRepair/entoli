import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/workspace/workspace_page.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;
  late String root;

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
    await pumpUntil(tester, find.byType(ListTile));
    await settleIo(tester);
  }

  void start({FakeFileHandoff? handoff}) {
    app = TestApp.create(handoff: handoff);
    root = app.config.projectWorkspaceDir();
  }

  tearDown(() => app.dispose());

  group("listing", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    testWidgets("draws the folder it was opened at", (tester) async {
      seed(files: ["notes.md", "main.dart"], folders: ["src"]);
      await open(tester);

      expect(find.text("Chat workspace"), findsOneWidget);
      expect(find.text("src"), findsOneWidget);
      expect(find.text("notes.md"), findsOneWidget);
      expect(find.text("main.dart"), findsOneWidget);
    });

    testWidgets("a file shows its size and a folder does not", (tester) async {
      seed(files: ["notes.md"], folders: ["src"]);
      await open(tester);

      expect(find.text("20 B"), findsOneWidget);
      expect(
        find.descendant(of: find.widgetWithText(ListTile, "src"), matching: find.text("0 B")),
        findsNothing,
      );
    });

    testWidgets("an empty workspace says so rather than drawing nothing", (tester) async {
      await app.pump(tester, WorkspacePage(root: root, title: "Chat workspace"));
      await pumpUntil(tester, find.text("Nothing here yet"));

      expect(find.text("Nothing here yet"), findsOneWidget);
    });
  });

  group("moving around", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    testWidgets("tapping a folder descends into it", (tester) async {
      seed(files: ["src/main.dart"]);
      await open(tester);

      await tester.tap(find.text("src"));
      await settleIo(tester);

      expect(find.text("main.dart"), findsOneWidget);
      // The app bar names the folder, and the path under it says which one.
      expect(find.text("src"), findsNWidgets(2));
    });

    testWidgets("back climbs one folder before it leaves the page", (tester) async {
      seed(files: ["src/deep/main.dart"]);
      await open(tester);

      await tester.tap(find.text("src"));
      await settleIo(tester);
      await tester.tap(find.text("deep"));
      await settleIo(tester);
      expect(find.text("main.dart"), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settleIo(tester);
      expect(find.text("deep"), findsOneWidget);
      expect(find.text("main.dart"), findsNothing);

      await tester.tap(find.byType(BackButton));
      await settleIo(tester);
      expect(find.text("Chat workspace"), findsOneWidget);
    });

    testWidgets("tapping a file hands it to the platform's viewer", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      await tester.tap(find.text("notes.md"));
      await settleIo(tester);

      expect(app.handoff.opened, ["$root/notes.md"]);
    });
  });

  group("desktop", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    testWidgets("the title bar opens the folder in the file manager", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      await tester.tap(find.byTooltip("Show in file manager"));
      await settleIo(tester);

      expect(app.handoff.revealed, [root]);
    });

    testWidgets("it reveals the folder being looked at, not the root", (tester) async {
      seed(files: ["src/main.dart"]);
      await open(tester);
      await tester.tap(find.text("src"));
      await settleIo(tester);

      await tester.tap(find.byTooltip("Show in file manager"));
      await settleIo(tester);

      expect(app.handoff.revealed, ["$root/src"]);
    });

    testWidgets("there is nothing to select, share or upload", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      expect(find.byTooltip("Select"), findsNothing);
      expect(find.byTooltip("Upload"), findsNothing);
    });
  });

  group("android", () {
    setUp(() => start(handoff: FakeFileHandoff.android()));

    testWidgets("has no file manager and no chooser of its own", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      expect(find.byTooltip("Show in file manager"), findsNothing);
      expect(find.byTooltip("Upload"), findsNothing);
    });

    testWidgets("a selection goes out through the share sheet", (tester) async {
      seed(files: ["a.txt", "b.txt"]);
      await open(tester);

      await tester.tap(find.byTooltip("Select"));
      await settleIo(tester);
      await tester.tap(find.text("a.txt"));
      await tester.tap(find.text("b.txt"));
      await settleIo(tester);

      expect(find.text("2 selected"), findsOneWidget);
      await tester.tap(find.text("Share"));
      await settleIo(tester);

      expect(app.handoff.exported, [
        unorderedEquals(["$root/a.txt", "$root/b.txt"]),
      ]);
    });

    testWidgets("a folder can be shared as well as a file", (tester) async {
      seed(files: ["src/main.dart", "a.txt"]);
      await open(tester);

      await tester.tap(find.byTooltip("Select"));
      await settleIo(tester);
      await tester.tap(find.text("src"));
      await settleIo(tester);
      await tester.tap(find.text("Share"));
      await settleIo(tester);

      expect(app.handoff.exported, [
        ["$root/src"],
      ]);
    });

    testWidgets("a long press selects without the toolbar", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.longPress(find.text("a.txt"));
      await settleIo(tester);

      expect(find.text("1 selected"), findsOneWidget);
    });

    testWidgets("cancelling a selection puts the listing back", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.longPress(find.text("a.txt"));
      await settleIo(tester);
      await tester.tap(find.byTooltip("Cancel selection"));
      await settleIo(tester);

      expect(find.text("1 selected"), findsNothing);
      expect(find.text("Chat workspace"), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });

    // A selection is one folder's, so the staging directory the share sheet is
    // handed can stay flat. Leaving the folder is the only way out of one.
    testWidgets("leaving the folder clears what was selected", (tester) async {
      seed(files: ["a.txt", "src/main.dart"]);
      await open(tester);
      await tester.tap(find.text("src"));
      await settleIo(tester);

      await tester.longPress(find.text("main.dart"));
      await settleIo(tester);
      expect(find.text("1 selected"), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settleIo(tester);

      expect(find.text("1 selected"), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
    });
  });

  group("getting there", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    testWidgets("the chat settings page opens the chat's own workspace", (tester) async {
      final chat = await io(tester, () => app.seedChat());
      final workspace = app.config.workspaceDir(chat.state.id);
      Directory(workspace).createSync(recursive: true);
      File("$workspace/scratch.txt").writeAsStringSync("chat");

      await app.pump(tester, ChatSettingsPage(chatId: chat.state.id));
      await pumpUntil(tester, find.text("Workspace"));
      await tester.tap(find.text("Workspace"));
      await settleIo(tester);

      expect(find.text("Chat workspace"), findsOneWidget);
      expect(find.text("scratch.txt"), findsOneWidget);
    });

    testWidgets("a chat in a project opens the workspace it actually has",
        (tester) async {
      final chat = await io(tester, () => app.seedChat(project: "research"));
      final workspace =
          app.config.workspaceDir(chat.state.id, project: "research");
      Directory(workspace).createSync(recursive: true);
      File("$workspace/in-project.txt").writeAsStringSync("x");

      await app.pump(tester, ChatSettingsPage(chatId: chat.state.id));
      await pumpUntil(tester, find.text("Workspace"));
      await tester.tap(find.text("Workspace"));
      await settleIo(tester);

      expect(find.text("in-project.txt"), findsOneWidget);
    });

    testWidgets("the project settings page opens the shared workspace", (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      final shared = app.config.projectWorkspaceDir(project: "research");
      File("$shared/shared.md").writeAsStringSync("everyone's");

      await app.pump(tester, const ProjectSettingsPage(project: "research"));
      await tester.tap(find.text("Workspace"));
      await settleIo(tester);

      expect(find.text("Project workspace"), findsOneWidget);
      expect(find.text("shared.md"), findsOneWidget);
    });
  });

  group("web", () {
    setUp(() => start(handoff: FakeFileHandoff.web()));

    testWidgets("the button says download rather than share", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.longPress(find.text("a.txt"));
      await settleIo(tester);

      expect(find.text("Download"), findsOneWidget);
      expect(find.text("Share"), findsNothing);
    });

    testWidgets("uploaded files land in the folder being looked at", (tester) async {
      seed(files: ["src/main.dart"]);
      await open(tester);
      await tester.tap(find.text("src"));
      await settleIo(tester);

      app.handoff.scriptedImport = [incomingFile("added.txt", "new")];
      await tester.tap(find.byTooltip("Upload"));
      await settleIo(tester);
      await tester.tap(find.text("Upload files"));
      await settleIo(tester);

      expect(app.handoff.imports, [false]);
      expect(File("$root/src/added.txt").readAsStringSync(), "new");
      expect(find.text("added.txt"), findsOneWidget);
    });

    testWidgets("uploading a folder asks for one and keeps its shape", (tester) async {
      await open(tester);

      app.handoff.scriptedImport = [
        incomingFile("notes/a.txt", "a"),
        incomingFile("notes/deep/b.txt", "b"),
      ];
      await tester.tap(find.byTooltip("Upload"));
      await settleIo(tester);
      await tester.tap(find.text("Upload folder"));
      await settleIo(tester);

      expect(app.handoff.imports, [true]);
      expect(File("$root/notes/a.txt").readAsStringSync(), "a");
      expect(File("$root/notes/deep/b.txt").readAsStringSync(), "b");
      expect(find.text("notes"), findsOneWidget);
    });

    testWidgets("a cancelled chooser leaves the folder alone", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      app.handoff.scriptedImport = const [];
      await tester.tap(find.byTooltip("Upload"));
      await settleIo(tester);
      await tester.tap(find.text("Upload files"));
      await settleIo(tester);

      expect(Directory(root).listSync().length, 1);
    });
  });

  group("formatSize", () {
    test("reads in whichever unit keeps it short", () {
      expect(formatSize(0), "0 B");
      expect(formatSize(512), "512 B");
      expect(formatSize(1536), "1.5 KB");
      expect(formatSize(20 * 1024), "20 KB");
      expect(formatSize(5 * 1024 * 1024), "5.0 MB");
    });
  });
}
