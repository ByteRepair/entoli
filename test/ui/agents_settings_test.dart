import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/agent_pictures.dart"
    show readAgentPicture;
import "package:agent_chat/data/prompts/prompt_sources.dart" show promptTiers;
import "package:agent_chat/domain/agent_definition.dart";
import "package:agent_chat/domain/agent_face.dart";
import "package:agent_chat/domain/bot_avatar/spec.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/project.dart" show localProject;
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart"
    show ProjectSettingsPage;
import "package:agent_chat/ui/widgets/agent_picture.dart";

import "../fakes.dart" show onePixelPng, testAttachment;
import "../harness.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  // The bundled agents the default project ships: athena, explore and general. The
  // esbmc-verifier is byte-repair's alone, so it is not in the default library.
  const bundledAgents = ["athena", "explore", "general"];

  group("the agents settings page", () {
    testWidgets("lists the bundled agents and tags them Bundled", (
      tester,
    ) async {
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
      expect(
        find.byType(AgentPicture),
        findsAtLeastNWidgets(bundledAgents.length),
      );
    });

    testWidgets("adding a user agent writes its file, and a photo picked on "
        "its row lands beside it", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await scrollTo(tester, find.text("Add agent"));
      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "researcher");
      await tester.enterText(find.byType(TextField).at(1), "A research agent");
      await writePrompt(
        tester,
        "You are a research agent.",
        label: "System prompt",
      );
      await save(tester);

      final dir = app.config.promptsDir(CompletionKind.agent);
      final file = File("$dir/researcher.md");
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains("You are a research agent."));
      // Tools left at their defaults write no list.
      expect(file.readAsStringSync(), isNot(contains("tools:")));

      // The user's own row: no Bundled tag, and its own actions.
      expect(find.text("researcher"), findsOneWidget);
      await pickImage(tester, app, "researcher", name: "photo.png");
      expect(File("$dir/researcher.png").readAsBytesSync(), onePixelPng);
    });

    testWidgets("the tool switches write the agent's list: a group's switch "
        "takes all of it, and the read-only shell replaces the full one", (
      tester,
    ) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await scrollTo(tester, find.text("Add agent"));
      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "looker");
      await writePrompt(tester, "You look.", label: "System prompt");

      Future<void> flip(String label) async {
        final tile = find.widgetWithText(SwitchListTile, label);
        await tester.scrollUntilVisible(
          tile,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(tile);
        await tester.pump();
      }

      await flip("Files");
      await flip("bash(readonly)");
      await save(tester);

      final source = File(
        "${app.config.promptsDir(CompletionKind.agent)}/looker.md",
      ).readAsStringSync();
      final tools = AgentDefinition.of(
        PromptDocument.parse(CompletionKind.agent, "looker", source),
      ).tools!;
      expect(tools, contains("bash(readonly)"));
      expect(tools, contains("websearch"));
      expect(tools, isNot(contains("bash")));
      expect(tools.intersection({"read", "write", "edit"}), isEmpty);
    });

    testWidgets("editing a user agent rewrites its file", (tester) async {
      final file = File(
        "${app.config.promptsDir(CompletionKind.agent)}/researcher.md",
      );
      newFile(file.path, "---\ndescription: Old desc\n---\n\nOld body.");

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await openRow(tester, "researcher");

      // The form is filled with the agent's contents. The name is first, and
      // editable: editing it renames the agent.
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        "researcher",
      );
      await tester.enterText(find.byType(TextField).at(1), "New desc");
      // The body is shown, not typed in: it is written on a page of its own.
      expect(find.text("Old body."), findsOneWidget);
      await writePrompt(tester, "New body.", label: "System prompt");
      expect(find.text("New body."), findsOneWidget);
      await save(tester);

      expect(file.readAsStringSync(), contains("New body."));
      expect(file.readAsStringSync(), contains("New desc"));
    });

    testWidgets("renaming a user agent writes the new file and removes the "
        "old one, picture included", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile(
        "$dir/researcher.md",
        "---\ndescription: Old desc\n---\n\nOld body.",
      );
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await openRow(tester, "researcher");

      await tester.enterText(find.byType(TextField).at(0), "archivist");
      await save(tester);

      expect(
        File("$dir/archivist.md").readAsStringSync(),
        contains("Old body."),
      );
      expect(File("$dir/researcher.md").existsSync(), isFalse);
      // The picture follows the name.
      expect(File("$dir/archivist.png").readAsBytesSync(), onePixelPng);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
      // The list follows the rename.
      expect(find.text("archivist"), findsOneWidget);
      expect(find.text("researcher"), findsNothing);
    });

    testWidgets("renaming onto a taken name is refused in the editor", (
      tester,
    ) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      for (final name in ["researcher", "archivist"]) {
        newFile("$dir/$name.md", "---\ndescription: desc\n---\n\nBody.");
      }

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await openRow(tester, "researcher");

      await tester.enterText(find.byType(TextField).at(0), "archivist");
      await save(tester);

      // Still on the editor with the error; no file was touched.
      expect(
        find.text("An agent with that name is already installed."),
        findsOneWidget,
      );
      expect(File("$dir/researcher.md").readAsStringSync(), contains("Body."));
      expect(File("$dir/archivist.md").readAsStringSync(), contains("Body."));
    });

    testWidgets("deleting a user agent removes its file and its picture", (
      tester,
    ) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await rowAction(tester, "researcher", "Remove");
      // The confirm dialog.
      await tester.tap(find.text("Remove").last);
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.md").existsSync(), isFalse);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("a name that is not a file name is refused", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await scrollTo(tester, find.text("Add agent"));
      await tester.tap(find.text("Add agent"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "../escape");
      await save(tester);

      // Still on the editor page with an error, and no file written.
      expect(find.textContaining("cannot be a file name"), findsOneWidget);
      expect(
        File(
          "${app.config.promptsDir(CompletionKind.agent)}/../escape.md",
        ).existsSync(),
        isFalse,
      );
    });

    testWidgets("a Bot Avatar chosen for an agent is written as "
        "<name>.avatar.json and takes the photo's place", (tester) async {
      useWindow(tester, const Size(480, 1500));
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);
      // The presets are an asset read, which wants a real clock to land.
      await tester.runAsync(
        () => app.container.read(botAvatarPresetsProvider.future),
      );

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      // A live avatar never comes to rest, so from here it is frames.
      await rowAction(tester, "researcher", "Bot Avatar…", settle: false);
      await tester.tap(find.bySemanticsLabel("Ghost"));
      await frames(tester);
      await tester.tap(find.text("Use"));
      await frames(tester);
      await settleIo(tester, least: 15);

      final spec = BotAvatarSpec.decode(
        File("$dir/researcher.avatar.json").readAsStringSync(),
      );
      expect(spec?.definition.id, "ghost");
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("View Bot Avatars opens the avatars to look through, with "
        "nothing to use one for", (tester) async {
      useWindow(tester, const Size(480, 1500));
      await tester.runAsync(
        () => app.container.read(botAvatarPresetsProvider.future),
      );
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await scrollTo(tester, find.text("View Bot Avatars"));
      await tester.tap(find.text("View Bot Avatars"));
      await frames(tester);
      expect(find.text("Bot Avatars"), findsOneWidget);
      expect(find.bySemanticsLabel("Ghost"), findsWidgets);
      expect(find.text("Use"), findsNothing);
    });

    testWidgets("a pick that is not a .png is refused", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await pickImage(tester, app, "researcher", name: "photo.jpg");

      expect(find.textContaining("pick a PNG image"), findsOneWidget);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("removing an agent's picture deletes the file", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await rowAction(tester, "researcher", "Remove picture");
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("saving an edit leaves the picture alone", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", onePixelPng);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);
      await openRow(tester, "researcher");
      await tester.enterText(find.byType(TextField).at(1), "Still mine");
      await save(tester);

      expect(File("$dir/researcher.png").readAsBytesSync(), onePixelPng);
    });

    testWidgets("an inherited picture shows on the project's row", (
      tester,
    ) async {
      // The default project holds the picture; the agent list here shows the
      // tiers' answer.
      await io(tester, () => app.repo.createProject("work"));
      final defaults = app.config.promptsDir(
        CompletionKind.agent,
        project: "default",
      );
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

      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, "researcher"),
          matching: find.byType(AgentPicture),
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final face = await readAgentPicture(
          app.config,
          "researcher",
          promptTiers(project: "work", config: app.config),
        );
        expect((face! as AgentPhoto).bytes, onePixelPng);
      });
    });

    testWidgets("an agent added and removed on the global page reaches the "
        "other projects' @ menus", (tester) async {
      // No manual reload after the save: the reload the page does itself is
      // what is under test. A My Team chat's menu reads its own project's
      // library, whose default rung is the directory the global page wrote.
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await scrollTo(tester, find.text("Add agent"));
      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "researcher");
      await tester.enterText(find.byType(TextField).at(1), "A research agent");
      await writePrompt(
        tester,
        "You are a research agent.",
        label: "System prompt",
      );
      await save(tester);

      Iterable<String> myTeam() => app.container
          .read(
            completionsProvider((
              project: localProject("my-team"),
              kind: CompletionKind.agent,
            )),
          )
          .map((option) => option.name);
      expect(myTeam(), contains("researcher"));

      // Removing it reaches the menus the same way, the page's own reload
      // again the witness.
      await rowAction(tester, "researcher", "Remove");
      await tester.tap(find.text("Remove").last);
      await settleIo(tester, least: 15);

      expect(myTeam(), isNot(contains("researcher")));
    });

    testWidgets("a picture picked on the global page reaches the other "
        "projects' avatars", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/scout.md", "---\ndescription: A scout.\n---\n\nScout.");
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      // Hold the member a My Team chat's avatar reads from across the save,
      // so the answer under it is the save's doing and not a fresh read.
      final hold = app.container.listen(
        agentPictureProvider((project: "my-team", name: "scout")),
        (_, _) {},
      );
      addTearDown(hold.close);
      expect(
        await tester.runAsync(
          () => app.container.read(
            agentPictureProvider((project: "my-team", name: "scout")).future,
          ),
        ),
        isNull,
      );

      await pickImage(tester, app, "scout", name: "photo.png");

      expect(
        await tester.runAsync(
          () => app.container.read(
            agentPictureProvider((project: "my-team", name: "scout")).future,
          ),
        ),
        isA<AgentPhoto>().having((f) => f.bytes, "bytes", onePixelPng),
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

      await scrollTo(tester, find.text("Add agent"));
      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await tester.enterText(find.byType(TextField).at(0), "tester");
      await tester.enterText(find.byType(TextField).at(1), "A test agent");
      await writePrompt(tester, "You test things.", label: "System prompt");
      await save(tester);

      expect(
        app.container
            .read(
              completionsProvider((
                project: localProject("work"),
                kind: CompletionKind.agent,
              )),
            )
            .map((option) => option.name),
        contains("tester"),
      );
    });
  });
}

/// Save on the form page's bar.
Future<void> save(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(
    find.descendant(of: find.byType(AppBar), matching: find.text("Save")),
  );
  await settleIo(tester, least: 15);
}

/// The row of [name]'s agent, opened to edit.
Future<void> openRow(WidgetTester tester, String name) async {
  await scrollTo(tester, find.widgetWithText(ListTile, name));
  await tester.tap(
    find.descendant(
      of: find.widgetWithText(ListTile, name),
      matching: find.text(name),
    ),
  );
  await settleIo(tester);
}

/// A picture picked for [agent] on its row: the chooser is
/// `AttachmentPicker`, which the harness fakes, so scripting the answer and
/// running the row's Upload photo is the whole of it — the pick carries
/// [onePixelPng] under [name].
Future<void> pickImage(
  WidgetTester tester,
  TestApp app,
  String agent, {
  required String name,
}) async {
  app.picker.scripted = [
    testAttachment(name, mimeType: "image/png", bytes: onePixelPng),
  ];
  addTearDown(() => app.picker.scripted = const []);
  await rowAction(tester, agent, "Upload photo");
  await settleIo(tester, least: 15);
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
