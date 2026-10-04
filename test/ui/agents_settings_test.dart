import "dart:io";
import "dart:typed_data";

import "package:file_selector/file_selector.dart" show XFile, XTypeGroup;
import "package:file_selector_platform_interface/file_selector_platform_interface.dart"
    show FileSelectorPlatform;
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:plugin_platform_interface/plugin_platform_interface.dart"
    show MockPlatformInterfaceMixin;

import "package:agent_chat/data/prompts/agent_pictures.dart"
    show readAgentPicture;
import "package:agent_chat/data/prompts/prompt_sources.dart" show promptTiers;
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart"
    show ProjectSettingsPage;
import "package:agent_chat/ui/widgets/agent_picture.dart";

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
    });

    testWidgets("adding a user agent writes a .md file and shows it with edit and remove", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "researcher");
      await tester.enterText(find.byType(TextField).at(1), "A research agent");
      await tester.enterText(find.byType(TextField).at(2), "You are a research agent.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      // The file landed on disk.
      final file = File("${app.config.promptsDir(CompletionKind.agent)}/researcher.md");
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains("You are a research agent."));

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
      // Unspecified reads as enabled, so the disabled state is what is asserted
      // against.
      expect(tester.widget<TextField>(find.byType(TextField).at(0)).enabled,
          isNot(false));

      await tester.enterText(find.byType(TextField).at(1), "New desc");
      await tester.enterText(find.byType(TextField).at(2), "New body.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(file.readAsStringSync(), contains("New body."));
      expect(file.readAsStringSync(), contains("New desc"));
    });

    testWidgets("renaming a user agent writes the new file and removes the "
        "old one", (tester) async {
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

      await tester.enterText(find.byType(TextField).at(0), "archivist");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final newFile = File("${app.config.promptsDir(CompletionKind.agent)}/archivist.md");
      expect(newFile.existsSync(), isTrue);
      expect(newFile.readAsStringSync(), contains("Old body."));
      expect(file.existsSync(), isFalse);
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

    testWidgets("deleting a user agent removes its file", (tester) async {
      final file = File("${app.config.promptsDir(CompletionKind.agent)}/researcher.md");
      await io(tester, () async {
        await file.create(recursive: true);
        await file.writeAsString("---\ndescription: desc\n---\n\nBody.");
      });

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

      expect(file.existsSync(), isFalse);
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

    testWidgets("the agent row's leading element is the picture slot", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      // Every row leads with the circle: the person mark where no picture is
      // set, which is what the bundled agents answer by default.
      expect(find.byType(AgentPicture), findsAtLeastNWidgets(bundledAgents.length));
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
      await pickImage(tester, name: "photo.png");
      expect(find.textContaining("is set on save"), findsOneWidget);

      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final image = File("$dir/researcher.png");
      expect(image.existsSync(), isTrue);
      expect(image.readAsBytesSync(), pngBytes);
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
      await pickImage(tester, name: "photo.jpg");

      // Still on the editor, nothing set, no file written.
      expect(find.textContaining("pick a PNG image"), findsOneWidget);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("the editor shows the picture the agent already has, and "
        "removing it deletes the file", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", pngBytes);

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
      newFileBytes("$dir/researcher.png", pngBytes);

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

      expect(File("$dir/researcher.png").readAsBytesSync(), pngBytes);
    });

    testWidgets("a rename moves the picture with the agent", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", pngBytes);

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

      expect(File("$dir/researcher.png").existsSync(), isFalse);
      expect(File("$dir/archivist.png").readAsBytesSync(), pngBytes);
    });

    testWidgets("deleting a user agent removes its picture with it", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");
      newFileBytes("$dir/researcher.png", pngBytes);

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, "researcher"),
        matching: find.byIcon(Icons.close),
      ));
      await settleIo(tester);
      await tester.tap(find.text("Remove"));
      await settleIo(tester, least: 15);

      expect(File("$dir/researcher.md").existsSync(), isFalse);
      expect(File("$dir/researcher.png").existsSync(), isFalse);
    });

    testWidgets("an added agent can carry a picture from the start", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);
      await pickImage(tester, name: "photo.png");
      await tester.enterText(find.byType(TextField).at(0), "scout");
      await tester.enterText(find.byType(TextField).at(1), "A scout.");
      await tester.enterText(find.byType(TextField).at(2), "You are a scout.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final dir = app.config.promptsDir(CompletionKind.agent);
      expect(File("$dir/scout.md").existsSync(), isTrue);
      expect(File("$dir/scout.png").readAsBytesSync(), pngBytes);
    });

    testWidgets("an inherited picture shows on the row, not in this "
        "project's editor", (tester) async {
      // The default project holds the picture; the agent list here shows the
      // tiers' answer, the editor only what this directory has to edit.
      await io(tester, () => app.repo.createProject("work"));
      final defaults = app.config.promptsDir(CompletionKind.agent, project: "default");
      newFileBytes("$defaults/researcher.png", pngBytes);
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
        expect(bytes, pngBytes);
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

    testWidgets("an agent added on the global page is in the other projects' "
        "@ menus without a restart", (tester) async {
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
                (project: "my-team", kind: CompletionKind.agent)))
            .map((option) => option.name),
        contains("researcher"),
      );
    });

    testWidgets("removing an agent on the global page leaves the other "
        "projects' @ menus too", (tester) async {
      final dir = app.config.promptsDir(CompletionKind.agent);
      newFile("$dir/researcher.md", "---\ndescription: desc\n---\n\nBody.");

      await pumpSettings(tester, app, SettingsCategory.agents);
      // Both members built before the delete, so the answer under it is the
      // delete's own and not a read that never happened.
      await reloadLibrary(tester, app);
      await reloadLibrary(tester, app, project: "my-team");
      expect(
        app.container
            .read(completionsProvider(
                (project: "my-team", kind: CompletionKind.agent)))
            .map((option) => option.name),
        contains("researcher"),
      );

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
                (project: "my-team", kind: CompletionKind.agent)))
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
      await pickImage(tester, name: "photo.png");
      await tester.enterText(find.byType(TextField).at(0), "scout");
      await tester.enterText(find.byType(TextField).at(1), "A scout.");
      await tester.enterText(find.byType(TextField).at(2), "You are a scout.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      expect(
        await tester.runAsync(() => app.container
            .read(agentPictureProvider((project: "my-team", name: "scout")).future)),
        pngBytes,
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
            .read(completionsProvider((project: "work", kind: CompletionKind.agent)))
            .map((option) => option.name),
        contains("tester"),
      );
    });
  });
}

/// The bytes a test's pick brings in: the PNG signature, which is the whole
/// of what the extension refusal and the file assertions ask of them. A test
/// that renders them draws the fallback instead — decoding is not what those
/// assert.
final Uint8List pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // the PNG signature
  ...List.filled(16, 0x20),
]);

/// Simulate a picture pick: the editor's chooser is the platform's, so the
/// test takes `FileSelectorPlatform` over and answers it with a file carrying
/// [name] and the bytes above.
Future<void> pickImage(WidgetTester tester, {required String name}) async {
  final previous = FileSelectorPlatform.instance;
  FileSelectorPlatform.instance = _FakeFileSelector(name);
  addTearDown(() => FileSelectorPlatform.instance = previous);
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

class _FakeFileSelector extends Fake
    with MockPlatformInterfaceMixin
    implements FileSelectorPlatform {
  _FakeFileSelector(this.name);

  final String name;

  /// The name is where the editor's `.png` check reads it, and a read of the
  /// answer goes to the path — `XFile` answers `name` from it on io. So the
  /// fake writes the bytes to a scratch file and hands that back: no subclass
  /// of `XFile` to reimplement, which `cross_file` does not invite.
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final scratch = File("/tmp/entoli_test_pick_$name");
    scratch.writeAsBytesSync(pngBytes);
    addTearDown(scratch.deleteSync);
    return XFile(scratch.path);
  }
}

/// Reload the prompt library and settle, so the page reflects what is on disk
/// rather than the test's seeded library.
Future<void> reloadLibrary(WidgetTester tester, TestApp app,
    {String? project}) async {
  await tester.runAsync(
    () => app.container.read(promptLibraryProvider(project).notifier).reload(),
  );
  await settleIo(tester);
}