import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/settings/settings_page.dart"
    show SettingsCategory;
import "package:agent_chat/ui/skills/skill_install_preview.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/settings/agents_settings.dart";
import "package:agent_chat/ui/widgets/install_destination.dart";

import "../fakes.dart" show FakeChatStore;
import "../harness.dart";

const _skillMd =
    "---\nname: letterbox\ndescription: frames the reply\n---\n\nFrame.\n";

/// A home that pushes the preview page as soon as it is on screen, the way
/// `skill_install_preview_test.dart` does.
class _Launcher extends StatefulWidget {
  const _Launcher();

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const SkillInstallPreviewPage(
            chatId: "chat-1",
            installId: "install-1",
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

final _installButton = find.widgetWithText(FilledButton, "Install skill");

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  group("the project's skills page", () {
    testWidgets("the project's own entry is editable in its directory; the "
        "default project's is badged Inherited and read-only", (tester) async {
      // Both written before the page opens: the section scans its directory
      // once, the same one look the global page makes.
      await io(tester, () async {
        await app.repo.createProject("work");
        await writeSkill(app, "review");
        await writeSkill(app, "local-note", project: "work");
      });

      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Skills"));
      await tester.tap(find.text("Skills"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      // The bundled presets sort ahead of the user's entries, and the list
      // scrolls one way: `local-note` is brought up from below `review`
      // first, and `review` is then below it, still a forward scroll away.
      await scrollTo(tester, find.text("local-note"));
      expect(find.text("local-note"), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      // Removing it deletes the project's own directory, not the default's —
      // tapped while the row is on screen, since bringing `review` up from
      // below would take this one off the top of the window again.
      await tester.tap(find.byIcon(Icons.close));
      await settleIo(tester);
      await tester.tap(find.text("Remove"));
      await settleIo(tester, least: 15);

      final dir = app.config.promptsDir(CompletionKind.skill, project: "work");
      expect(Directory("$dir/local-note").existsSync(), isFalse);
      expect(Directory(
              "${app.config.promptsDir(CompletionKind.skill)}/review")
          .existsSync(),
        isTrue);

      // The default project's entry is badged Inherited and read-only.
      await scrollTo(tester, find.text("review"));
      expect(find.text("review"), findsOneWidget);
      expect(find.text("Inherited"), findsOneWidget);
    });

    testWidgets("a user project's page imports, without the destination "
        "combobox the global page carries", (tester) async {
      await io(tester, () => app.repo.createProject("work"));
      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Skills"));
      await tester.tap(find.text("Skills"));
      await settleIo(tester);

      expect(find.text("Import skill"), findsOneWidget);
      expect(find.text("Install to"), findsNothing);
    });

    testWidgets("the global page keeps its import flow and its destination",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.skills);
      expect(find.text("Import skill"), findsOneWidget);
      expect(find.byType(InstallDestination), findsOneWidget);
    });
  });

  group("the project's agents page", () {
    testWidgets("a project agent is written and edited in the project's "
        "directory; the default project's is badged, not editable",
        (tester) async {
      await io(tester, () => app.repo.createProject("work"));

      await app.pump(tester, const ProjectSettingsPage(project: "work"));
      await scrollTo(tester, find.text("Agents"));
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "work");

      // Reloaded, the library is the real sources: the bundled agents for
      // both projects, and none of the test's seed. The default project's
      // are inherited here.
      expect(find.byType(AgentsSection), findsOneWidget);
      expect(find.text("general"), findsOneWidget);
      expect(find.text("Bundled"), findsNWidgets(2));
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.text("Add agent"), findsOneWidget);

      await tester.tap(find.text("Add agent"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField).at(0), "tester");
      await tester.enterText(find.byType(TextField).at(1), "A test agent");
      await tester.enterText(find.byType(TextField).at(2), "You test things.");
      await tester.tap(find.text("Save"));
      await settleIo(tester, least: 15);

      final file = File(
          "${app.config.promptsDir(CompletionKind.agent, project: "work")}/tester.md");
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains("You test things."));

      // Own rows edit and remove; removing takes the project's file only.
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await settleIo(tester);
      await tester.tap(find.text("Remove"));
      await settleIo(tester, least: 15);
      expect(file.existsSync(), isFalse);
      // The default project's agents are untouched.
      final globalDir = Directory(app.config.promptsDir(CompletionKind.agent));
      expect(globalDir.existsSync() && globalDir.listSync().isNotEmpty,
          isFalse);
    });

    testWidgets("the global agents page has no destination combobox",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.agents);
      expect(find.byType(InstallDestination), findsNothing);
    });
  });

  group("the built-in's pages", () {
    testWidgets("Byte Repair's page lists its bundled agent read-only",
        (tester) async {
      await app.pump(tester, ProjectSettingsPage(project: "byte-repair"));
      await scrollTo(tester, find.text("Agents"));
      await tester.tap(find.text("Agents"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "byte-repair");

      // Its own bundled agent, and the two defaults it inherits — all
      // bundled, all inert.
      expect(find.text("esbmc-verifier"), findsOneWidget);
      expect(find.text("Bundled"), findsNWidgets(3));
      expect(find.text("Inherited"), findsNothing);
      expect(find.text("Add agent"), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets("Byte Repair's skills page is read-only and has no destination",
        (tester) async {
      await app.pump(tester, ProjectSettingsPage(project: "byte-repair"));
      await scrollTo(tester, find.text("Skills"));
      await tester.tap(find.text("Skills"));
      await settleIo(tester);
      await reloadLibrary(tester, app, project: "byte-repair");

      // The bundled presets the library serves every project — the
      // locally written skills, one badge each.
      await scrollTo(tester, find.text("artifact"));
      expect(find.text("artifact"), findsOneWidget);
      expect(find.text("Bundled"), findsWidgets);
      expect(find.text("Import skill"), findsNothing);
      expect(find.byType(InstallDestination), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group("the install destination", () {
    testWidgets("the project picked on the preview page is where the skill "
        "lands", (tester) async {
      final store = FakeChatStore();
      app = TestApp.create(store: store);
      await io(tester, () => app.repo.createProject("work"));

      final bytes = packageSkillBytes(SkillPackage("letterbox", [
        ("SKILL.md", Uint8List.fromList(utf8.encode(_skillMd))),
      ]));
      store.stageSkillInstall("chat-1", "install-1", bytes);

      await app.pump(tester, const _Launcher(), settle: false);
      await pumpUntil(tester, _installButton);
      await settleIo(tester);

      // Global is the default; the user's projects are the other choices.
      await tester.tap(find.byType(InstallDestination));
      await tester.pumpAndSettle();
      expect(popupLabels(tester), containsAll(<String>["Global", "work"]));
      await tester.tap(find.text("work").last);
      await settleIo(tester);

      await tester.tap(_installButton);
      await settleIo(tester, least: 20, tries: 80);

      final dir =
          skillDirectory(app.config, "letterbox", project: "work");
      expect(File("$dir/SKILL.md").existsSync(), isTrue);
      expect(Directory(skillDirectory(app.config, "letterbox")).existsSync(),
          isFalse);
    });
  });

  group("isBundledPromptName", () {
    test("names the embedded presets, per kind and per project", () {
      expect(isBundledPromptName(CompletionKind.skill, "artifact"), isTrue);
      expect(isBundledPromptName(CompletionKind.skill, "esbmc-verifier"),
          isFalse);
      expect(
        isBundledPromptName(CompletionKind.agent, "esbmc-verifier",
            project: "byte-repair"),
        isTrue,
      );
      expect(isBundledPromptName(CompletionKind.agent, "esbmc-verifier"),
          isFalse);
      expect(isBundledPromptName(CompletionKind.agent, "general"), isTrue);
      expect(isBundledPromptName(CompletionKind.skill, "review"), isFalse);
    });
  });
}