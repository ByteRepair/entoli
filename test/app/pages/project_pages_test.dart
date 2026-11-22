import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/project_settings.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/domain/confinement.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/work_folders.dart";
import "package:agent_chat/domain/tristate.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/app/selection.dart";

import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  group("a project's settings", () {
    Future<PageDriver<ProjectSettingsAppPage>> open(String project) async {
      final page = PageDriver(app, ProjectSettingsAppPage(project));
      await page.until(() => page.find<ActionController>("name") != null);
      return page;
    }

    test("its rows are the settings' own, at the project's level", () async {
      await app.repo.createProject("work");
      final page = await open("work");
      expect(page.find<CollectionController>("permissions"), isNotNull);
      expect(page.find<ToggleController>("sandbox"), isNotNull);
      expect(page.find<SettingController>("turnMaxSteps"), isNotNull);
      final memory = page.at<ChoiceController<Tristate>>("memory");
      await memory.set(Tristate.on);
      expect(
        app.container.read(projectSettingsProvider("work")).memory,
        Tristate.on,
      );
    });

    test("Omada's rows come with it", () async {
      await app.repo.createProject("work");
      final page = await open("work");
      expect(page.find<SettingController>("omadaOrdering"), isNull);
      await page.at<ToggleController>("omada").set(true);
      await page.until(
        () => page.find<SettingController>("omadaOrdering") != null,
      );
    });

    test(
      "a built-in project has no description and cannot be deleted",
      () async {
        final page = await open("byte-repair");
        expect(page.find<TextController>("description"), isNull);
        expect(page.find<ActionController>("delete"), isNull);
      },
    );

    test("deleting asks, then takes the project and its chats", () async {
      await app.repo.createProject("work");
      await app.repo.createChat(project: "work");
      final page = await open("work");
      final delete = page.at<ActionController>("delete");
      expect((await delete.confirm())?.message, contains("its 1 chat"));
      await delete.run();
      expect(page.open, isFalse);
      expect(await app.repo.listProjects(), isNot(contains("work")));
    });

    test("Omada's ordering, set here, is the project's", () async {
      await app.repo.createProject("research");
      final page = await open("research");
      await page.at<ToggleController>("omada").set(true);
      await page.until(
        () => page.find<ChoiceController>("omadaOrdering") != null,
      );
      await page
          .at<ChoiceController<OmadaOrdering>>("omadaOrdering")
          .set(OmadaOrdering.parallel);
      final saved = ProjectSettings.load(app.config, project: "research");
      expect(
        (saved.omada, saved.omadaOrdering),
        (true, OmadaOrdering.parallel),
      );
    });

    test("a built-in's Omada is its spec: shown, not offered", () async {
      final repair = await open("byte-repair");
      expect(repair.at<ToggleController>("omada").enabled, isFalse);
      expect(repair.find<ChoiceController>("omadaOrdering"), isNull);
      final team = await open("my-team");
      expect(team.at<ToggleController>("omada").value, isTrue);
      expect(team.at<ToggleController>("omada").enabled, isFalse);
      expect(team.find<ChoiceController>("omadaOrdering"), isNotNull);
    });

    test(
      "a blank description asks nothing; its reset asks the default",
      () async {
        await app.repo.createProject("research");
        final page = await open("research");
        await page
            .at<TextController>("description")
            .set("What are we building?");
        expect(
          ProjectSettings.load(app.config, project: "research").description,
          "What are we building?",
        );
        await page.at<TextController>("description").set("");
        expect(
          ProjectSettings.load(app.config, project: "research").description,
          "",
        );
        expect(page.at<TextController>("description").emptyLabel, "Empty");
        await page.at<TextController>("description").accessory!.run();
        expect(
          ProjectSettings.load(app.config, project: "research").description,
          isNull,
        );
      },
    );

    test("the name copies itself, and the chats are counted", () async {
      await app.repo.createProject("research");
      await app.seedChat(project: "research");
      final page = await open("research");
      final notice = await page.at<ActionController>("name").run();
      expect(
        (notice?.message, notice?.copy),
        ("Copied project name", "research"),
      );
      await page.until(
        () => page.at<InfoController>("chats").rows.single.subtitle == "1",
      );
    });

    test("deleting the assistant's project lets go of it", () async {
      await app.repo.createProject("work");
      await app.container
          .read(appSettingsProvider.notifier)
          .setAssistantProject("work");
      final page = await open("work");
      await page.at<ActionController>("delete").run();
      expect(app.container.read(appSettingsProvider).assistantProject, isNull);
      expect(app.container.read(selectedProjectProvider).project, isNull);
    });

    test("permissions and the sandbox are the project's own", () async {
      final repair = await open("byte-repair");
      expect(
        repair.at<CollectionController>("permissions").addLabel,
        "Add rule",
      );
      await app.repo.createProject("research");
      final page = await open("research");
      await page.at<ToggleController>("sandbox").set(false);
      expect(
        ProjectSettings.load(app.config, project: "research").sandbox,
        isFalse,
      );
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

    Future<PageDriver<ProjectSettingsAppPage>> open({
      List<String>? folders,
    }) async {
      await app.repo.createProject("research");
      if (folders != null) {
        await app.container
            .read(projectSettingsProvider("research").notifier)
            .setWritableDirs(folders);
      }
      final page = PageDriver(app, ProjectSettingsAppPage("research"));
      await page.until(() => page.find<ActionController>("addFolder") != null);
      return page;
    }

    List<String> saved() =>
        ProjectSettings.load(app.config, project: "research").writableDirs;

    test("a picked folder is added, and removing it takes it out", () async {
      final page = await open();
      app.folders.scripted = outside.path;
      await page.at<ActionController>("addFolder").run();
      expect(saved(), [outside.path]);
      await page.until(
        () =>
            page.at<CollectionController<String>>("folderList").items.length ==
            1,
      );
      await page.at<CollectionController<String>>("folderList").remove(0);
      expect(saved(), isEmpty);
    });

    test("the app's own data directory is refused", () async {
      final page = await open();
      app.folders.scripted = app.config.dataDir;
      final notice = await page.at<ActionController>("addFolder").run();
      expect(notice?.message, FolderRefusal.appData.message);
      expect(saved(), isEmpty);
    });

    test("a folder gone from this device says so in its row", () async {
      final gone = "${outside.path}/gone";
      final page = await open(folders: [gone]);
      expect(
        page
            .at<CollectionController<String>>("folderList")
            .rows
            .single
            .subtitle,
        "Missing on this device",
      );
    });

    for (final confinement in [Confinement.none, Confinement.appSandbox]) {
      test(
        "${confinement.name} confines nothing, so there is no list",
        () async {
          app.dispose();
          app = TestApp.create(hostConfinement: confinement);
          await app.repo.createProject("research");
          final page = PageDriver(app, ProjectSettingsAppPage("research"));
          await page.until(() => page.find<ActionController>("name") != null);
          expect(page.find<ActionController>("addFolder"), isNull);
        },
      );
    }
  });
}
