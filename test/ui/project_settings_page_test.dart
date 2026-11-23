import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/selection.dart";
import "package:entoli_chat/domain/confinement.dart";
import "package:entoli_chat/domain/project_settings.dart";
import "package:entoli_chat/domain/tristate.dart";
import "package:entoli_chat/domain/work_folders.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/project_actions.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// Opened over a host page, as the sidebar opens it, so a delete has
  /// somewhere to go back to.
  Future<void> open(WidgetTester tester, String project) async {
    useWindow(tester, const Size(1000, 4000));
    await app.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                openProjectSettings(context, (device: null, project: project)),
            child: const Text("host"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("host"));
    await settleIo(tester);
  }

  Future<void> create(WidgetTester tester, String project) =>
      io(tester, () => app.repo.createProject(project));

  ProjectSettings saved(String project) =>
      ProjectSettings.load(app.config, project: project);

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  group("a project's settings", () {
    testWidgets("its rows are the settings' own, at the project's level", (
      tester,
    ) async {
      await create(tester, "work");
      await open(tester, "work");
      expect(find.text("Add rule"), findsOneWidget);
      expect(find.text("Sandbox — Default (on)"), findsOneWidget);
      expect(find.text("System temp folders"), findsOneWidget);
      expect(find.text("Max steps per turn"), findsOneWidget);

      await tester.tap(find.text("Own"));
      await settleIo(tester);
      expect(saved("work").memory, Tristate.on);
      expect(find.text("This project keeps memories of its own."), findsOne);
    });

    testWidgets("Omada's rows come with it, and its ordering is the "
        "project's", (tester) async {
      await create(tester, "research");
      await open(tester, "research");
      expect(find.text("Default round order"), findsNothing);

      await tester.tap(find.widgetWithText(SwitchListTile, "Omada"));
      await settleIo(tester);
      expect(find.text("Default round order"), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text("Default round order"),
                matching: find.byType(Column),
              )
              .first,
          matching: find.byType(InputDecorator),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text("Crossfire").last);
      await settleIo(tester);
      expect(
        (saved("research").omada, saved("research").omadaOrdering),
        (true, OmadaOrdering.parallel),
      );
    });

    testWidgets("a built-in has no description and cannot be deleted, and "
        "its Omada is its spec", (tester) async {
      await open(tester, "byte-repair");
      expect(find.text("Description"), findsNothing);
      expect(find.text("Delete Project"), findsNothing);
      final omada = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, "Omada"),
      );
      expect(omada.onChanged, isNull);
      expect(find.text("Default round order"), findsNothing);
      // Its permissions are still its own.
      expect(find.text("Add rule"), findsOneWidget);
    });

    testWidgets("My Team's Omada is on, shown and not offered", (tester) async {
      await open(tester, "my-team");
      final omada = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, "Omada"),
      );
      expect((omada.value, omada.onChanged == null), (true, true));
      expect(find.text("Default round order"), findsOneWidget);
    });

    testWidgets("deleting asks, counting the chats, then takes the project", (
      tester,
    ) async {
      await create(tester, "work");
      await io(tester, () => app.repo.createChat(project: "work"));
      await open(tester, "work");

      await tester.tap(find.text("Delete Project"));
      await settleIo(tester);
      expect(find.textContaining("its 1 chat "), findsOneWidget);
      await tester.tap(inDialog("Delete"));
      await settleIo(tester);

      expect(find.byType(ProjectSettingsPage), findsNothing);
      expect(
        await io(tester, () => app.repo.listProjects()),
        isNot(contains("work")),
      );
    });

    testWidgets("deleting the assistant's project lets go of it", (
      tester,
    ) async {
      await create(tester, "work");
      await io(
        tester,
        () => app.container
            .read(appSettingsProvider.notifier)
            .setAssistantProject("work"),
      );
      await open(tester, "work");
      await tester.tap(find.text("Delete Project"));
      await settleIo(tester);
      await tester.tap(inDialog("Delete"));
      await settleIo(tester);

      expect(app.container.read(appSettingsProvider).assistantProject, isNull);
      expect(app.container.read(selectedProjectProvider).project, isNull);
    });

    testWidgets("a blank description asks nothing; its reset asks the "
        "default", (tester) async {
      await create(tester, "research");
      await open(tester, "research");
      expect(find.byTooltip("Reset to the default question"), findsNothing);

      Future<void> describe(String text) async {
        await tester.tap(find.text("Description"));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          text,
        );
        await tester.tap(inDialog("Save"));
        await settleIo(tester);
      }

      await describe("What are we building?");
      expect(saved("research").description, "What are we building?");
      expect(find.text("What are we building?"), findsOneWidget);

      await describe("");
      expect(saved("research").description, "");
      expect(find.text("Empty"), findsOneWidget);

      await tester.tap(find.byTooltip("Reset to the default question"));
      await settleIo(tester);
      expect(saved("research").description, isNull);
    });

    testWidgets("the name copies itself, and the chats are counted", (
      tester,
    ) async {
      final copied = clipboard(tester);
      await create(tester, "research");
      await io(tester, () => app.seedChat(project: "research"));
      await open(tester, "research");

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, "Project name"),
          matching: find.text("Copy"),
        ),
      );
      await settleIo(tester);
      expect(copied, ["research"]);
      expect(find.text("Copied project name"), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, "Chats"),
          matching: find.text("1"),
        ),
        findsOneWidget,
      );
    });

    testWidgets("the sandbox is the project's own", (tester) async {
      await create(tester, "research");
      await open(tester, "research");
      await tester.tap(find.widgetWithText(SwitchListTile, "Sandbox"));
      await settleIo(tester);
      expect(saved("research").sandbox, isFalse);
    });
  });

  group("a project's work folders", () {
    late Directory outside;

    setUp(() {
      app.dispose();
      app = TestApp.create(hostConfinement: Confinement.seatbelt);
      outside = Directory.systemTemp.createTempSync("work-folder");
    });
    tearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });

    Future<void> openWith(WidgetTester tester, {List<String>? folders}) async {
      await create(tester, "research");
      if (folders != null) {
        await io(
          tester,
          () => app.container
              .read(projectSettingsProvider("research").notifier)
              .setWritableDirs(folders),
        );
      }
      await open(tester, "research");
    }

    testWidgets("a picked folder is added, and removing it takes it out", (
      tester,
    ) async {
      await openWith(tester);
      expect(find.text("No folders yet."), findsOneWidget);
      app.folders.scripted = outside.path;
      await tester.tap(find.text("Add Folder…"));
      await settleIo(tester);
      expect(saved("research").writableDirs, [outside.path]);
      expect(find.text(outside.path), findsOneWidget);

      await tester.tap(find.byTooltip("Remove ${outside.path}"));
      await settleIo(tester);
      expect(saved("research").writableDirs, isEmpty);
    });

    testWidgets("the app's own data directory is refused", (tester) async {
      await openWith(tester);
      app.folders.scripted = app.config.dataDir;
      await tester.tap(find.text("Add Folder…"));
      await settleIo(tester);
      expect(find.text(FolderRefusal.appData.message), findsOneWidget);
      expect(saved("research").writableDirs, isEmpty);
    });

    testWidgets("a folder gone from this device says so in its row", (
      tester,
    ) async {
      await openWith(tester, folders: ["${outside.path}/gone"]);
      expect(find.text("Missing on this device"), findsOneWidget);
    });

    for (final confinement in [Confinement.none, Confinement.appSandbox]) {
      testWidgets("${confinement.name} confines nothing, so there is no "
          "list", (tester) async {
        app.dispose();
        app = TestApp.create(hostConfinement: confinement);
        await create(tester, "research");
        await open(tester, "research");
        expect(find.text("Project name"), findsOneWidget);
        expect(find.text("Add Folder…"), findsNothing);
      });
    }
  });
}
