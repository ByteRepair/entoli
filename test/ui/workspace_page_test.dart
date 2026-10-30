import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:re_editor/re_editor.dart";

import "package:agent_chat/domain/workspace.dart";
import "package:agent_chat/ui/chat/chat_settings_page.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";
import "package:agent_chat/core/formatting.dart";
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

  Future<void> deleteSelection(WidgetTester tester) async {
    await tester.tap(find.byTooltip("Delete"));
    await settleIo(tester);
    await tester.tap(find.widgetWithText(TextButton, "Delete"));
    await settleIo(tester);
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

      // The system back gesture climbs too, not only the bar's arrow.
      await tester.binding.handlePopRoute();
      await settleIo(tester);
      expect(find.text("deep"), findsOneWidget);
      expect(find.text("main.dart"), findsNothing);

      await tester.tap(find.byType(BackButton));
      await settleIo(tester);
      expect(find.text("Chat workspace"), findsOneWidget);
    });

    testWidgets("tapping a file it cannot read hands it to the platform",
        (tester) async {
      seed(files: ["photo.png"]);
      await open(tester);

      await tester.tap(find.text("photo.png"));
      await settleIo(tester);

      expect(app.handoff.opened, ["$root/photo.png"]);
    });
  });

  group("viewing a text file", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    Future<void> view(WidgetTester tester, String name) async {
      await tester.tap(find.text(name));
      await settleIo(tester);
    }

    testWidgets("tapping one reads it in the app rather than handing it over",
        (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      await view(tester, "notes.md");

      expect(find.text("contents of notes.md"), findsOneWidget);
      expect(app.handoff.opened, isEmpty);
    });

    Future<void> fromMenu(WidgetTester tester, String item) async {
      await tester.tap(find.byTooltip("More"));
      await settleIo(tester);
      await tester.tap(find.text(item));
      await settleIo(tester);
    }

    CodeLineEditingController editor(WidgetTester tester) =>
        tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

    testWidgets("the app bar still opens it in another app", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);
      await view(tester, "notes.md");

      await fromMenu(tester, "Open in another app");
      await settleIo(tester);

      expect(app.handoff.opened, ["$root/notes.md"]);
      expect(find.text("contents of notes.md"), findsOneWidget);
    });

    testWidgets("what is shown can be copied", (tester) async {
      final copied = clipboard(tester);
      seed(files: ["notes.md"]);
      await open(tester);
      await view(tester, "notes.md");

      await fromMenu(tester, "Copy");

      expect(copied, ["contents of notes.md"]);
    });

    testWidgets("code opens read-only in the editor until Edit", (tester) async {
      seed(files: ["main.dart"]);
      await open(tester);
      await view(tester, "main.dart");

      expect(editor(tester).text, "contents of main.dart");
      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isTrue);

      await tester.tap(find.byTooltip("Edit"));
      await settleIo(tester);

      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isFalse);
    });

    testWidgets("markdown previews rendered and edits as source", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);
      await view(tester, "notes.md");
      expect(find.byType(CodeEditor), findsNothing);

      await tester.tap(find.byTooltip("Edit"));
      await settleIo(tester);

      expect(editor(tester).text, "contents of notes.md");
    });

    testWidgets("an edit is saved back to the file", (tester) async {
      seed(files: ["main.dart"]);
      await open(tester);
      await view(tester, "main.dart");
      await tester.tap(find.byTooltip("Edit"));
      await settleIo(tester);

      editor(tester).text = "void main() {}";
      await settleIo(tester);
      await tester.tap(find.byTooltip("Save"));
      await settleIo(tester);

      expect(File("$root/main.dart").readAsStringSync(), "void main() {}");
    });

    testWidgets("leaving with unsaved edits asks first", (tester) async {
      seed(files: ["main.dart"]);
      await open(tester);
      await view(tester, "main.dart");
      await tester.tap(find.byTooltip("Edit"));
      await settleIo(tester);
      editor(tester).text = "changed";
      await settleIo(tester);

      await tester.tap(find.byType(BackButton));
      await settleIo(tester);
      expect(find.text("Discard your changes?"), findsOneWidget);
      await tester.tap(find.text("Discard"));
      await settleIo(tester);

      expect(find.text("Chat workspace"), findsOneWidget);
      expect(File("$root/main.dart").readAsStringSync(), "contents of main.dart");
    });

    testWidgets("lines wrap from the menu", (tester) async {
      seed(files: ["main.dart"]);
      await open(tester);
      await view(tester, "main.dart");

      await fromMenu(tester, "Wrap lines");

      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).wordWrap, isTrue);
      await fromMenu(tester, "Wrap lines");
    });

    testWidgets("a file past the cap is not shown, but can be opened or copied whole",
        (tester) async {
      final copied = clipboard(tester);
      final big = "x" * (textViewLimit + 10);
      File("$root/big.log")
        ..createSync(recursive: true)
        ..writeAsStringSync(big);
      await open(tester);
      await view(tester, "big.log");

      expect(find.text("Too large to show here"), findsOneWidget);
      expect(find.byType(CodeEditor), findsNothing);
      expect(find.byTooltip("Edit"), findsNothing);

      await tester.tap(find.text("Copy text"));
      await settleIo(tester);
      expect(copied, [big]);

      await tester.tap(find.text("Open in another app"));
      await settleIo(tester);
      expect(app.handoff.opened, ["$root/big.log"]);
    });

    // The extension is only the first half of the rule: a `.log` the agent
    // wrote as a gzip goes back out to the platform rather than being drawn.
    testWidgets("one whose bytes are not text falls back to the hand-off",
        (tester) async {
      File("$root/a.log")
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x1f, 0x8b, 0x00, 0x42]);
      await open(tester);

      await view(tester, "a.log");

      expect(app.handoff.opened, ["$root/a.log"]);
      expect(find.text("Chat workspace"), findsOneWidget);
    });

    testWidgets("one deleted under the reader says so rather than drawing nothing",
        (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);
      File("$root/notes.md").deleteSync();

      await view(tester, "notes.md");

      expect(find.text("That file could not be read"), findsOneWidget);
    });
  });

  group("desktop", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    testWidgets("it reveals the folder being looked at, not the root", (tester) async {
      seed(files: ["src/main.dart"]);
      await open(tester);

      // At the root, the root.
      await tester.tap(find.byTooltip("Show in file manager"));
      await settleIo(tester);
      expect(app.handoff.revealed, [root]);

      // Descended, what is on screen.
      await tester.tap(find.text("src"));
      await settleIo(tester);
      await tester.tap(find.byTooltip("Show in file manager"));
      await settleIo(tester);

      expect(app.handoff.revealed.last, "$root/src");
    });

    // Selecting survives having nowhere to share to, because deleting is not a
    // route out of the app.
    testWidgets("there is nothing to share, but there is to select",
        (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      expect(find.byTooltip("Select"), findsOneWidget);
    });

    testWidgets("a selection can be deleted with nowhere to send it", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.longPress(find.text("a.txt"));
      await settleIo(tester);
      expect(find.byType(FloatingActionButton), findsNothing);

      await deleteSelection(tester);

      expect(File("$root/a.txt").existsSync(), isFalse);
    });
  });

  group("android", () {
    setUp(() => start(handoff: FakeFileHandoff.android()));

    testWidgets("has no file manager", (tester) async {
      seed(files: ["notes.md"]);
      await open(tester);

      expect(find.byTooltip("Show in file manager"), findsNothing);
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

  group("making a folder", () {
    setUp(() => start(handoff: FakeFileHandoff.desktop()));

    Future<void> newFolder(WidgetTester tester, String name) async {
      await tester.tap(find.byTooltip("New folder"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField), name);
      await tester.tap(find.text("Create"));
      await settleIo(tester);
    }

    testWidgets("it lands in the folder being looked at", (tester) async {
      seed(files: ["src/main.dart"]);
      await open(tester);
      await tester.tap(find.text("src"));
      await settleIo(tester);

      await newFolder(tester, "notes");

      expect(Directory("$root/src/notes").existsSync(), isTrue);
      expect(find.text("notes"), findsOneWidget);
    });

    testWidgets("a typed path cannot climb out of the workspace", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await newFolder(tester, "../escaped");

      expect(Directory("$root/escaped").existsSync(), isTrue);
      expect(Directory("${app.config.dataDir}/escaped").existsSync(), isFalse);
    });

    testWidgets("a dismissed dialog creates nothing", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.tap(find.byTooltip("New folder"));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(TextButton, "Cancel"));
      await settleIo(tester);

      expect(Directory(root).listSync().length, 1);
    });
  });

  group("deleting", () {
    setUp(() => start(handoff: FakeFileHandoff.android()));

    testWidgets("a folder goes with everything in it", (tester) async {
      seed(files: ["src/deep/main.dart", "keep.txt"]);
      await open(tester);

      await tester.longPress(find.text("src"));
      await settleIo(tester);
      await deleteSelection(tester);

      expect(Directory("$root/src").existsSync(), isFalse);
      expect(File("$root/keep.txt").existsSync(), isTrue);
      expect(find.text("src"), findsNothing);
    });

    testWidgets("several files go at once, and the selection ends", (tester) async {
      seed(files: ["a.txt", "b.txt", "c.txt"]);
      await open(tester);

      await tester.tap(find.byTooltip("Select"));
      await settleIo(tester);
      await tester.tap(find.text("a.txt"));
      await tester.tap(find.text("b.txt"));
      await settleIo(tester);
      await deleteSelection(tester);

      expect(Directory(root).listSync().map((e) => e.path), ["$root/c.txt"]);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text("Chat workspace"), findsOneWidget);
    });

    testWidgets("a cancelled confirmation leaves everything", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);

      await tester.longPress(find.text("a.txt"));
      await settleIo(tester);
      await tester.tap(find.byTooltip("Delete"));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(TextButton, "Cancel"));
      await settleIo(tester);

      expect(File("$root/a.txt").existsSync(), isTrue);
      expect(find.text("1 selected"), findsOneWidget);
    });

    testWidgets("there is nothing to delete until something is picked", (tester) async {
      seed(files: ["a.txt"]);
      await open(tester);
      expect(find.byTooltip("Delete"), findsNothing);

      await tester.tap(find.byTooltip("Select"));
      await settleIo(tester);
      expect(find.byTooltip("Delete"), findsNothing);

      await tester.tap(find.text("a.txt"));
      await settleIo(tester);
      expect(find.byTooltip("Delete"), findsOneWidget);
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

    testWidgets("the sidebar opens the default project's workspace", (tester) async {
      seed(files: ["shared.md"]);

      await app.pump(tester, const SizedBox(width: 280, child: Sidebar()));
      await tester.tap(find.byTooltip("Default workspace"));
      await settleIo(tester);

      expect(find.text("Default workspace"), findsOneWidget);
      expect(find.text("shared.md"), findsOneWidget);
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
