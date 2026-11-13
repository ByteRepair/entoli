import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/pages/context.dart";
import "package:agent_chat/app/pages/text_file.dart";
import "package:agent_chat/app/pages/workspace.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/core/formatting.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/workspace.dart";

import "../../fakes.dart";
import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;
  late String root;

  void start({FakeFileHandoff? handoff}) {
    app = TestApp.create(handoff: handoff);
    root = app.config.projectWorkspaceDir();
  }

  tearDown(() => app.dispose());

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

  Future<PageDriver<WorkspaceAppPage>> open({String? dir}) async {
    final page = PageDriver(
      app,
      WorkspaceAppPage(root: root, owner: "Chat workspace", dir: dir),
    );
    await page.until(
      () => page.find<CollectionController<WorkspaceEntry>>("entries") != null,
    );
    return page;
  }

  List<CollectionItem> rows(PageDriver<WorkspaceAppPage> page) =>
      page.at<CollectionController<WorkspaceEntry>>("entries").rows;

  group("the explorer", () {
    test("a file shows its size, a folder none, folders first", () async {
      start();
      seed(files: ["notes.txt"], folders: ["src"]);
      final page = await open();
      expect(rows(page).map((r) => r.title), ["src", "notes.txt"]);
      expect(rows(page).first.subtitle, isNull);
      expect(
        rows(page).last.subtitle,
        formatSize("contents of notes.txt".length),
      );
    });

    test("an empty workspace says so", () async {
      start();
      final page = await open();
      final entries = page.at<CollectionController<WorkspaceEntry>>("entries");
      expect(entries.items, isEmpty);
      expect(entries.emptyLabel, startsWith("Nothing here yet."));
    });

    test("a folder opens over the page, under where it sits", () async {
      start();
      seed(files: ["src/main.dart"], folders: ["src"]);
      final page = await open();
      await page
          .at<CollectionController<WorkspaceEntry>>("entries")
          .act(0, "open");
      final stack = app.container.read(appPagesProvider);
      final inner = stack.last as WorkspaceAppPage;
      expect(inner.dir, "$root/src");
      expect(inner.subtitle(page.reader), "src");
    });

    test("a text file opens in the app, anything else is handed off", () async {
      final handoff = FakeFileHandoff();
      start(handoff: handoff);
      seed(files: ["readme.md", "photo.png"]);
      final page = await open();
      final entries = page.at<CollectionController<WorkspaceEntry>>("entries");
      await entries.act(1, "open");
      expect(app.container.read(appPagesProvider).last, isA<TextFileAppPage>());
      await entries.act(0, "open");
      expect(handoff.opened, ["$root/photo.png"]);
    });

    test("a new folder lands in the folder being looked at", () async {
      start();
      seed(folders: ["src"]);
      final page = await open(dir: "$root/src");
      await page.at<CollectionController<WorkspaceEntry>>("entries").submit({
        "name": "lib",
      });
      expect(Directory("$root/src/lib").existsSync(), isTrue);
      await page.until(() => rows(page).any((r) => r.title == "lib"));
    });

    test("deleting asks first, and a folder goes with what is in it", () async {
      start();
      seed(files: ["src/a.txt"], folders: ["src"]);
      final page = await open();
      final delete = rows(
        page,
      ).single.actions.firstWhere((a) => a.id == "delete");
      expect(delete.confirm?.destructive, isTrue);
      await page
          .at<CollectionController<WorkspaceEntry>>("entries")
          .act(0, "delete");
      expect(Directory("$root/src").existsSync(), isFalse);
    });

    test("a desktop shows the folder being looked at, not the root", () async {
      final handoff = FakeFileHandoff(canReveal: true);
      start(handoff: handoff);
      seed(folders: ["src"]);
      final page = await open(dir: "$root/src");
      await page.tool("reveal").run();
      expect(handoff.revealed, ["$root/src"]);
    });

    test("a phone shares an entry, and has no file manager", () async {
      final handoff = FakeFileHandoff(canShare: true);
      start(handoff: handoff);
      seed(files: ["a.txt"]);
      final page = await open();
      expect(page.findTool("reveal"), isNull);
      await page
          .at<CollectionController<WorkspaceEntry>>("entries")
          .act(0, "share");
      expect(handoff.exported, [
        ["$root/a.txt"],
      ]);
    });
  });

  group("a text file", () {
    Future<PageDriver<TextFileAppPage>> view(String name) async {
      final page = PageDriver(
        app,
        TextFileAppPage(path: "$root/$name", name: name),
      );
      await page.until(() => page.find<DocumentController>("text") != null);
      return page;
    }

    test("is read, not edited, until Edit", () async {
      start();
      seed(files: ["main.dart"]);
      final page = await view("main.dart");
      final text = page.at<DocumentController>("text");
      expect(text.text, "contents of main.dart");
      expect(text.editing, isFalse);
      expect(text.markdown, isFalse);
      await page.tool("mode").run();
      expect(page.at<DocumentController>("text").editing, isTrue);
    });

    test("markdown is said to be markdown", () async {
      start();
      seed(files: ["README.md"]);
      expect(
        (await view("README.md")).at<DocumentController>("text").markdown,
        isTrue,
      );
    });

    test("an edit is saved back, and leaving with one unsaved asks", () async {
      start();
      seed(files: ["notes.txt"]);
      final page = await view("notes.txt");
      await page.tool("mode").run();
      page.at<DocumentController>("text").edit("changed");
      expect(page.page.leaving(page.reader), isNotNull);
      await page.tool("save").run();
      expect(File("$root/notes.txt").readAsStringSync(), "changed");
      expect(page.page.leaving(page.reader), isNull);
    });

    test("Copy puts the text on the clipboard as it is said", () async {
      start();
      seed(files: ["notes.txt"]);
      final notice = await (await view("notes.txt")).tool("copy").run();
      expect(notice?.copy, "contents of notes.txt");
    });

    test("one past the limit is not shown, only opened or copied", () async {
      start();
      File("$root/big.log")
        ..createSync(recursive: true)
        ..writeAsStringSync("x" * (textViewLimit + 1));
      final page = PageDriver(
        app,
        TextFileAppPage(path: "$root/big.log", name: "big.log"),
      );
      await page.until(() => page.find<ActionController>("open") != null);
      expect(page.find<DocumentController>("text"), isNull);
      final notice = await page.at<ActionController>("copy").run();
      expect(notice?.copy?.length, textViewLimit + 1);
    });

    test("bytes that are not text go to another app", () async {
      final handoff = FakeFileHandoff();
      start(handoff: handoff);
      File("$root/data.txt")
        ..createSync(recursive: true)
        ..writeAsBytesSync([0, 1, 2]);
      final page = PageDriver(
        app,
        TextFileAppPage(path: "$root/data.txt", name: "data.txt"),
      );
      await page.until(() => !page.open);
      expect(handoff.opened, ["$root/data.txt"]);
    });
  });

  group("the context", () {
    Message reply(String id, ContextUsage context, {String? author}) => Message(
      id: id,
      role: MessageRole.assistant,
      createdAt: DateTime.utc(2026),
      author: author,
      context: context,
    );

    test("a participant each, with what fills their window", () async {
      start();
      final chat = await app.seedChat();
      await app.writeChat(
        chat.copyWith(
          messages: [
            reply(
              "a1",
              const ContextUsage(
                system: 4000,
                tools: 6000,
                profile: 200,
                instructions: 3000,
                chat: 20000,
              ),
            ),
            reply(
              "a2",
              const ContextUsage(system: 100, tools: 100, profile: 0, chat: 50),
              author: "@reviewer",
            ),
          ],
        ),
      );
      final page = PageDriver(app, ContextAppPage(chat.state.id));
      await page.until(
        () =>
            page
                .find<CollectionController<String>>("participants")
                ?.items
                .length ==
            2,
      );
      final rows = page.at<CollectionController<String>>("participants").rows;
      expect(rows.map((r) => r.title), ["@athena", "@reviewer"]);
      final meter = rows.first.meters.single;
      expect(
        meter.segments.map((s) => "${s.label} · ${s.amount}"),
        contains("Instructions · 3.0k"),
      );
      expect(meter.mark?.label, "Auto-compact 80%");
      expect(meter.mark?.fraction, 0.8);
    });

    test("nothing measured says so", () async {
      start();
      final chat = await app.seedChat();
      final page = PageDriver(app, ContextAppPage(chat.state.id));
      final list = page.at<CollectionController<String>>("participants");
      expect(list.items, isEmpty);
      expect(list.emptyLabel, startsWith("Nothing measured yet."));
    });
  });
}
