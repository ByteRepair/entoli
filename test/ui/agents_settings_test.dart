import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

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
  });
}

/// Reload the prompt library and settle, so the page reflects what is on disk
/// rather than the test's seeded library.
Future<void> reloadLibrary(WidgetTester tester, TestApp app) async {
  await tester.runAsync(
    () => app.container.read(promptLibraryProvider(null).notifier).reload(),
  );
  await settleIo(tester);
}