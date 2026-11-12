import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/memory.dart";
import "package:agent_chat/app/pages/profile.dart";
import "package:agent_chat/app/pages/project_settings.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/domain/project.dart" show localProject;
import "package:agent_chat/domain/tone.dart";
import "package:agent_chat/domain/tristate.dart";
import "package:agent_chat/providers.dart";

import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  group("memories", () {
    late MemoryStore store;

    setUp(() => store = MemoryStore(app.config.memoryDir()));

    Future<PageDriver<MemoryAppPage>> open() async {
      final page = PageDriver(
        app,
        MemoryAppPage(project: localProject(null), owner: "Memories"),
      );
      await page.until(
        () => page.find<CollectionController<MemoryEntry>>("entries") != null,
      );
      return page;
    }

    List<CollectionItem> rows(PageDriver<MemoryAppPage> page) =>
        page.at<CollectionController<MemoryEntry>>("entries").rows;

    test("the store's memories, newest first", () async {
      await store.add("older");
      await store.add("newer", chat: "chat-1");
      final page = await open();
      expect(rows(page).map((r) => r.title), ["newer", "older"]);
      expect(rows(page).first.subtitle, endsWith("kept by the agent"));
    });

    test("a typed memory lands in the store and the list", () async {
      final page = await open();
      await page.at<CollectionController<MemoryEntry>>("entries").submit({
        "text": "  prefers tabs  ",
      });
      expect((await store.entries()).single.text, "prefers tabs");
      await page.until(() => rows(page).length == 1);
    });

    test("deleting asks, then the memory is gone from the list", () async {
      await store.add("forget me");
      final page = await open();
      final delete = rows(
        page,
      ).single.actions.firstWhere((a) => a.id == "delete");
      expect(delete.confirm?.title, "Delete memory?");
      await page
          .at<CollectionController<MemoryEntry>>("entries")
          .act(0, "delete");
      await page.until(() => rows(page).isEmpty);
    });

    test("a pin marks it; past the limit it is refused", () async {
      for (var i = 0; i < pinnedLimit; i++) {
        final entry = await store.add("standing $i");
        await store.pin(entry.id);
      }
      await store.add("one more");
      final page = await open();
      final refused = await page
          .at<CollectionController<MemoryEntry>>("entries")
          .act(0, "pin");
      expect(refused?.message, "Four is the most that can be pinned.");
      final all = await store.entries();
      expect(all.where((e) => e.text == "one more").single.pinned, isFalse);
    });

    test("a search narrows to the memories its words are in", () async {
      await store.add("likes rust");
      await store.add("dislikes meetings");
      final page = await open();
      await page.at<TextController>("search").set("rust");
      await page.until(() => rows(page).length == 1);
      expect(rows(page).single.title, "likes rust");
      await page.at<TextController>("search").set("nothing like it");
      await page.until(() => rows(page).isEmpty);
      expect(
        page.at<CollectionController<MemoryEntry>>("entries").emptyLabel,
        contains("nothing like it"),
      );
    });
  });

  group("the profile", () {
    Future<PageDriver<ProfileAppPage>> open({String? project}) async {
      final page = PageDriver(app, ProfileAppPage(project: project));
      await page.until(() => page.find<TextController>("instructions") != null);
      return page;
    }

    test("what is typed is saved whole, and the page goes", () async {
      final page = await open();
      await page.at<TextController>("name").set("Ada");
      await page.at<TextController>("instructions").set("Be brief.");
      await page.at<ChoiceController<Tone>>("tone").set(Tone.values.last);
      expect(page.page.leaving(page.reader), isNotNull);
      await page.tool("save").run();
      await page.until(() => !page.open);
      final settings = app.container.read(appSettingsProvider);
      expect(settings.profile?.name, "Ada");
      expect(settings.tone, Tone.values.last);
      expect(
        File(app.config.globalInstructionsFile).readAsStringSync(),
        "Be brief.",
      );
    });

    test("a date of birth not written as a date is refused", () async {
      final page = await open();
      await page.at<TextController>("dob").set("last tuesday");
      final notice = await page.tool("save").run();
      expect(notice?.message, contains("YYYY-MM-DD"));
      expect(page.open, isTrue);
    });

    test("a project's page is its instructions and its own answers", () async {
      await app.repo.createProject("work");
      final page = await open(project: "work");
      expect(page.find<TextController>("name"), isNull);
      final tone = page.at<ChoiceController<Tone>>("tone");
      expect(tone.unsettable, isTrue);
      expect(tone.inherited, Tone.none);
    });

    test("a desktop lists its linked files, a missing one said", () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final claude = File("${app.config.dataDir}/../linked/CLAUDE.md")
        ..createSync(recursive: true)
        ..writeAsStringSync("rules");
      File(app.config.linkedInstructionsFile)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            "files": [claude.absolute.path, "/nowhere/GONE.md"],
          }),
        );
      final page = await open();
      final linked = page.at<CollectionController<String>>("linked");
      expect(linked.rows.map((r) => r.title), ["CLAUDE.md", "GONE.md"]);
      expect(linked.rows.last.error, "Not found");
      await linked.act(1, "up");
      expect(
        page.at<CollectionController<String>>("linked").items.first,
        "/nowhere/GONE.md",
      );
    });

    test("off a desktop there is nothing to link", () async {
      final page = await open();
      expect(page.find<CollectionController<String>>("linked"), isNull);
    });
  });

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
  });
}
