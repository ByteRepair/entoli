import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/agent_pictures.dart"
    show readAgentPicture;
import "package:agent_chat/data/prompts/prompt_sources.dart" show promptTiers;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show localProject;
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart"
    show ProjectSettingsPage;
import "package:agent_chat/ui/widgets/agent_picture.dart";

import "../fakes.dart" show onePixelPng, testAttachment;
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  // The bundled agents the default project ships: explore and general. The
  // esbmc-verifier is byte-repair's alone, so it is not in the default library.
  const bundledAgents = ["explore", "general"];

  group("the agents settings page", () {
    testWidgets("lists the bundled agents and tags them Bundled", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);

      // The initial library is the test's, but the scan reads the real agents
      // directory (empty), so every agent is bundled from the library's side.
      // After the page's first scan completes, the bundled agents show their
      // tag. Reload to get the real bundled set rather than the test library's.
      await reloadLibrary(tester, app);

      for (final name in bundledAgents) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text("Bundled"), findsNWidgets(bundledAgents.length));
      // The bundled rows lead with the picture slot: the person mark where no
      // picture is set.
      expect(find.byType(AgentPicture), findsAtLeastNWidgets(bundledAgents.length));
    });

    testWidgets("adding a user agent writes its file and picture, and shows it with edit and remove", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await pickImage(tester, app, name: "photo.png");

      await tester.enterText(find.byType(TextField).at(0), "researcher");
      await tester.enterText(find.byType(TextField).at(1), "A research agent");
      await tester.enterText(find.byType(TextField).at(2), "You are a research agent.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      // The file and the picture picked alongside it landed on disk.
      final dir = app.config.promptsDir(CompletionKind.agent);
      final file = File("$dir/researcher.md");
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains("You are a research agent."));
      expect(File("$dir/researcher.png").readAsBytesSync(), onePixelPng);

      // The row shows the user agent with a remove button, not a Bundled tag.
      expect(find.text("researcher"), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    });

    testWidgets("editing a user agent rewrites its file", (tester) async {
      // Seed a user agent on disk before the page opens, so its initial scan
      // finds it and draws the row with edit and remove. The writes are real
      // file I/O, so they go through `runAsync`.
      final file = File("${app.config.promptsDir(CompletionKind.agent)}/researcher.md");
      await io(tester, () async {
        await file.create(recursive: true);
        await file.writeAsString("---\ndescription: Old desc\n---\n\nOld body.");
      });

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);

      // The editor is pre-filled with the agent's current contents. The name
      // field is first, and editable: editing it renames the agent.
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        "researcher",
      );
      await tester.enterText(find.byType(TextField).at(1), "New desc");
      await tester.enterText(find.byType(TextField).at(2), "New body.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(file.readAsStringSync(), contains("New body."));
      expect(file.readAsStringSync(), contains("New desc"));
    });

    testWidgets("renaming a user agent writes the new file and removes the "
        "old one, picture included", (tester) async {
      newFile("${app.config.promptsDir(CompletionKind.agent)}/researcher.md",
          "---\ndescription: Old desc\n---\n\nOld body.");
      newFileBytes("${app.config.promptsDir(CompletionKind.agent)}/researcher.png",
          onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "archivist");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final dir = app.config.promptsDir(CompletionKind.agent);
      expect(File("$dir/archivist.md").readAsStringSync(), contains("Old body."));
      expect(File("$dir/researcher.md").existsSync(), isFalse);
      // The picture follows the name.
      expect(File("$dir/archivist.png").readAsBytesSync(), onePixelPng);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
      // The list follows the rename.
      expect(find.text("archivist"), findsOneWidget);
      expect(find.text("researcher"), findsNothing);
    });

    testWidgets("renaming onto a taken name is refused in the editor", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      await io(tester, () async {
        for (final name in ["researcher", "archivist"]) {
          final file = File("$dir/$name.md");
          await file.create(recursive: true);
          await file.writeAsString("---\ndescription: desc\n---\n\nBody.");
        }
      });

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "archivist");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      // Still on the editor with the error; no file was touched.
      expect(find.text("An agent with that name already exists."), findsOneWidget);
      expect(File("$dir/researcher.md").readAsStringSync(), contains("Body."));
      expect(File("$dir/archivist.md").readAsStringSync(), contains("Body."));
    });

    testWidgets("deleting a user agent removes its file and its picture", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.close),
      ));
      await settleIo(tester);

      // The confirm dialog.
      await tester.tap(find.text("Remove"));
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.md").existsSync(), isFalse);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("a name that is not a file name is refused", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "../escape");
      await tester.enterText(find.byType(TextField).at(2), "body");
      await tester.tap(find.text("Save"));
      await settleIo(tester);

      // Still on the editor page with an error, and no file written.
      expect(find.textContaining("cannot be a file name"), findsOneWidget);
      expect(
        File("${app.config.promptsDir(CompletionKind.agent)}/../escape.md").existsSync(),
        isFalse,
      );
    });

    testWidgets("a picture picked in the editor is written as <name>.png "
        "beside the .md", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      // Open the editor, pick a picture, save.
      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);
      await pickImage(tester, app, name: "photo.png");
      expect(find.textContaining("is set on save"), findsOneWidget);

      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final image = File("$dir/researcher.png");
      expect(image.existsSync(), isTrue);
      expect(image.readAsBytesSync(), onePixelPng);
    });

    testWidgets("a pick that is not a .png is refused", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);
      await pickImage(tester, app, name: "photo.jpg");

      // Still on the editor, nothing set, no file written.
      expect(find.textContaining("pick a PNG image"), findsOneWidget);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("the editor shows the picture the agent already has, and "
        "removing it deletes the file", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);

      // The editor shows what is on disk, with a way to take it off.
      expect(find.textContaining("is set on save"), findsNothing);
      expect(find.textContaining("No picture"), findsNothing);
      await tester.tap(find.descendant(
        of: find.byType(ListView),
        matching: find.byIcon(Icons.close),
      ));
      await tester.pump();
      expect(find.text("The picture is removed on save."), findsOneWidget);

      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("saving without touching the picture leaves it alone", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);
      expect(find.textContaining("is set on save"), findsNothing);

      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.png").readAsBytesSync(), onePixelPng);
    });

    testWidgets("an inherited picture shows on the row, not in this "
        "project's editor", (tester) async {
      // The default project holds the picture; the agent list here shows the
      // tiers' answer, the editor only what this directory has to edit.
      await io(tester, () => app.repo.createProject("work"));
      final defaults = app.config.promptsDir(CompletionKind.agent, project: "default");
      newFileBytes("$defaults/researcher.png", onePixelPng);
      newFile(
        "${app.config.promptsDir(CompletionKind.agent, project: "work")}/researcher.md",
        "---\ndescription: desc\n---\n\nBody.",
      );

      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Agents"));
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      // The row's circle resolves the tiers and shows what was inherited.
      await tester.runAsync(() async {
        final bytes = await readAgentPicture(
          app.config,
          "researcher",
          promptTiers(project: "work", config: app.config),
        );
        expect(bytes, onePixelPng);
      });
      await settleIo(tester);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.edit_outlined),
      ));
      await settleIo(tester);

      // The editor shows this project's directory — nothing in it yet.
      expect(find.textContaining("No picture"), findsOneWidget);
      expect(find.textContaining("is set on save"), findsNothing);
    });

    testWidgets("an agent added and removed on the global page reaches the "
        "other projects' @ menus", (tester) async {
      // No manual reload after the save: the reload the page does itself is
      // what is under test. A My Team chat's menu reads its own project's
      // library, whose default rung is the directory the global page wrote.
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "researcher");
      await tester.enterText(find.byType(TextField).at(1), "A research agent");
      await tester.enterText(find.byType(TextField).at(2), "You are a research agent.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(
        app.container
            .read(completionsProvider(
                (project: localProject("my-team"), kind: CompletionKind.agent)))
            .map((option) => option.name),
        contains("researcher"),
      );

      // Removing it reaches the menus the same way, the page's own reload
      // again the witness.
      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.close),
      ));
      await settleIo(tester);
      await tester.tap(find.text("Remove"));
      await settleIo(tester, least: 15);

      expect(
        app.container
            .read(completionsProvider(
                (project: localProject("my-team"), kind: CompletionKind.agent)))
            .map((option) => option.name),
        isNot(contains("researcher")),
      );
    });

    testWidgets("a picture picked on the global page reaches the other "
        "projects' avatars", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      // Hold the member a My Team chat's avatar reads from across the save,
      // so the answer under it is the save's doing and not a fresh read.
      final hold = app.container
          .listen(agentPictureProvider((project: "my-team", name: "scout")), (_, _) {});
      addTearDown(hold.close);
      expect(
        await tester.runAsync(() => app.container
            .read(agentPictureProvider((project: "my-team", name: "scout")).future)),
        isNull,
      );

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await pickImage(tester, app, name: "photo.png");
      await tester.enterText(find.byType(TextField).at(0), "scout");
      await tester.enterText(find.byType(TextField).at(1), "A scout.");
      await tester.enterText(find.byType(TextField).at(2), "You are a scout.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(
        await tester.runAsync(() => app.container
            .read(agentPictureProvider((project: "my-team", name: "scout")).future)),
        onePixelPng,
      );
    });

    testWidgets("adding an agent on a project's own page reaches that "
        "project's @ menu", (tester) async {
      // One project's directory is one project's tier rung, so the reload a
      // project page does is enough — pinned here so it stays that way.
      await io(tester, () => app.repo.createProject("work"));
      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Agents"));
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "tester");
      await tester.enterText(find.byType(TextField).at(1), "A test agent");
      await tester.enterText(find.byType(TextField).at(2), "You test things.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(
        app.container
            .read(completionsProvider((project: localProject("work"), kind: CompletionKind.agent)))
            .map((option) => option.name),
        contains("tester"),
      );
    });
  });
}

/// Simulate a picture pick: the editor's chooser is `AttachmentPicker`, which
/// the harness fakes, so scripting the answer and tapping the picture is the
/// whole of it — the pick carries [onePixelPng] under [name].
Future<void> pickImage(WidgetTester tester, TestApp app,
    {required String name}) async {
  app.picker.scripted = [
    testAttachment(name, mimeType: "image/png", bytes: onePixelPng),
  ];
  addTearDown(() => app.picker.scripted = const []);
  // The picture itself is the tap target — the row the editor draws it in.
  await tester.tap(find.byTooltip("Choose a profile picture"));
  await tester.pump();
  await settleIo(tester);
}

/// Seeding a directory before any widget is pumped needs no runAsync; these
/// are the test body's own synchronous writes.
void newFile(String path, String text) {
  final file = File(path);
  file.createSync(recursive: true);
  file.writeAsStringSync(text);
}

void newFileBytes(String path, List<int> bytes) {
  final file = File(path);
  file.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}