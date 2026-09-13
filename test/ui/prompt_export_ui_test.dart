import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/settings/settings_page.dart" show SettingsCategory;
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/widgets/install_destination.dart";

import "../harness.dart";

final _exportButtons = find.byIcon(Icons.download);

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  group("skill export", () {
    testWidgets("a user skill saves through the backup handoff and imports "
        "back to the same skill", (tester) async {
      await io(tester, () async {
        await app.repo.createProject("work");
        await writeSkill(app, "review", project: "work");
      });

      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Skills"));
      await tester.tap(find.text("Skills"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      // The bundled presets plus the project's own review — every row
      // exports. The fetched skills lengthen the list, so what is counted is
      // that the row exists and exports, not how many rows there are.
      expect(_exportButtons, findsWidgets);
      await scrollTo(tester, find.byTooltip("Export review"));
      await tester.tap(find.byTooltip("Export review"));
      await settleIo(tester, least: 10);

      expect(app.backups.saved, hasLength(1));
      final saved = app.backups.saved.single;
      expect(saved.name, "review.skill");

      final package = parseSkillPackage(saved.bytes);
      expect(package.name, "review");
      expect(package.body, contains("Do review."));

      // What landed is the same shape an install offers: it re-installs.
      await io(tester,
          () => installSkillPackage(app.config, package, project: "work"));
      expect(
        File(
                "${app.config.promptsDir(CompletionKind.skill, project: "work")}/review/SKILL.md")
            .existsSync(),
        isTrue,
      );
    });

    testWidgets("a bundled skill exports from the embedded preset",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.skills);
      await reloadLibrary(tester, app);

      // No directory scan needed — export is on every row, scan or not.
      // The fetched presets lengthen the list; the point here is that a
      // bundled row's export reads the embedded preset, wherever it sits.
      expect(_exportButtons, findsWidgets);
      await scrollTo(tester, find.byTooltip("Export artifact"));
      await tester.tap(find.byTooltip("Export artifact"));
      await settleIo(tester, least: 10);

      final saved = app.backups.saved.single;
      expect(saved.name, "artifact.skill");
      final package = parseSkillPackage(saved.bytes);
      expect(package.name, "artifact");
      expect(package.body, isNot(contains("Base directory")));
    });

    testWidgets("a user agent saves its .md through the same handoff",
        (tester) async {
      final file = File("${app.config.promptsDir(CompletionKind.agent)}/researcher.md");
      await io(tester, () async {
        await file.create(recursive: true);
        await file.writeAsString("---\ndescription: A researcher\n---\n\nDig.");
      });

      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      await tester.tap(find.byTooltip("Export researcher"));
      await settleIo(tester, least: 10);

      final saved = app.backups.saved.single;
      expect(saved.name, "researcher.md");
      expect(utf8.decode(saved.bytes), file.readAsStringSync());
    });
  });

  group("the fixed footers", () {
    testWidgets("the skills page's import button stays put while the list "
        "scrolls", (tester) async {
      await io(tester, () async {
        for (var i = 0; i < 30; i++) {
          await writeSkill(app, "skill-$i");
        }
      });

      await pumpSettings(tester, app, SettingsCategory.skills);
      await reloadLibrary(tester, app);

      final importButton = find.text("Import skill");
      final before =
          tester.getTopRight(importButton).dy;
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.getTopRight(importButton).dy, before);
      expect(importButton, findsOneWidget);
      // The combo rides the footer with it.
      expect(find.byType(InstallDestination), findsOneWidget);
    });

    testWidgets("the agents page's add and import buttons stay put while the "
        "list scrolls", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      await reloadLibrary(tester, app);

      final addButton = find.text("Add agent");
      final importButton = find.text("Import agent");
      final before = tester.getTopRight(addButton).dy;
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.getTopRight(addButton).dy, before);
      expect(importButton, findsOneWidget);
    });
  });

  group("importing an agent", () {
    testWidgets("an .md written to the project's directory reloads the "
        "library with it", (tester) async {
      await io(tester, () => app.repo.createProject("work"));

      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Agents"));
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      expect(find.text("Import agent"), findsOneWidget);
      expect(find.text("Add agent"), findsOneWidget);

      await io(tester, () async {
        final file = File(
            "${app.config.promptsDir(CompletionKind.agent, project: "work")}/imported.md");
        await file.create(recursive: true);
        await file
            .writeAsString("---\ndescription: A test agent\n---\n\nBody.");
      });
      // The section's scan reads the directory once, at open; a change
      // behind the page's back is a restart's business. Re-open it.
      await pressBack(tester);
      await settleIo(tester);
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");
      expect(find.text("imported"), findsOneWidget);
      // The project's own row, against the inherited and bundled ones.
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets("the global page's import sits under the install-to combo "
        "in the footer", (tester) async {
      await pumpSettings(tester, app, SettingsCategory.skills);
      expect(find.text("Import skill"), findsOneWidget);
      expect(find.byType(InstallDestination), findsOneWidget);
    });
  });
}