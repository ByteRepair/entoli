import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/memory/store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/memory/memory_page.dart";
import "package:agent_chat/ui/settings/settings_page.dart";
import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/sidebar/sidebar.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  late String dir;
  late MemoryStore store;

  void start() {
    app = TestApp.create();
    dir = app.config.memoryDir();
    store = MemoryStore(app.config.fs, dir);
  }

  Future<void> open(WidgetTester tester) async {
    await app.pump(tester, MemoryPage(dir: dir, title: "Memories"));
    await pumpUntil(tester, find.byType(ListTile));
    await settleIo(tester);
  }

  /// The page's own store work: the action's settle starts the write, and a
  /// second one is where the write lands and the list reloads off it. The
  /// floor is what carries the rounds: while a disk write is in flight the
  /// tree is idle, and an idle frame is not evidence the write landed.
  Future<void> settled(WidgetTester tester) async {
    await settleIo(tester, least: 15);
    await settleIo(tester, least: 15);
  }

  Future<MemoryEntry> seed(WidgetTester tester, String text, {String? chat}) =>
      io(tester, () => store.add(text, chat: chat));

  tearDown(() {
    app.dispose();
  });

  group("listing", () {
    setUp(start);

    testWidgets("shows the store's memories, newest first", (tester) async {
      await seed(tester, "the project uses pnpm");
      await seed(tester, "deploy runs on fridays", chat: "chat-1");
      await open(tester);

      final tiles = tester
          .widgetList<ListTile>(find.descendant(
              of: find.byType(ListView), matching: find.byType(ListTile)))
          .map((t) => (t.title! as Text).data)
          .toList();
      expect(tiles, ["deploy runs on fridays", "the project uses pnpm"]);
      expect(find.textContaining("kept by the agent"), findsOneWidget);
      expect(find.textContaining("added by you"), findsOneWidget);
    });

    testWidgets("an empty store says so and offers to add one", (tester) async {
      await app.pump(tester, MemoryPage(dir: dir, title: "Memories"));
      await pumpUntil(tester, find.text("No memories yet"));

      expect(find.text("Add a memory"), findsOneWidget);
    });
  });

  group("adding", () {
    setUp(start);

    Future<void> typeAndSave(WidgetTester tester, String text) async {
      await tester.tap(find.byTooltip("Add a memory"));
      await settleIo(tester);
      await tester.enterText(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
        text,
      );
      await tester.tap(find.widgetWithText(FilledButton, "Save"));
      await settled(tester);
    }

    testWidgets("a typed memory lands in the store and the list", (tester) async {
      await open(tester);
      await typeAndSave(tester, "the user prefers dark mode");

      expect(find.text("the user prefers dark mode"), findsOneWidget);
      final entries = await io(tester, () => store.entries());
      expect(entries.map((e) => e.text), ["the user prefers dark mode"]);
      expect(entries.single.chat, isNull);
    });

    testWidgets("a dismissed dialog writes nothing", (tester) async {
      await open(tester);

      await tester.tap(find.byTooltip("Add a memory"));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(TextButton, "Cancel"));
      await settleIo(tester);

      expect(await io(tester, () => store.entries()), isEmpty);
    });
  });

  group("deleting", () {
    setUp(start);

    Future<void> deleteRow(WidgetTester tester) async {
      await tester.tap(find.byTooltip("Delete memory"));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(TextButton, "Delete"));
      await settled(tester);
    }

    testWidgets("a confirmed delete leaves a tombstone, not a gap", (tester) async {
      final entry = await seed(tester, "a learned detail");
      await open(tester);

      await deleteRow(tester);

      expect(find.text("a learned detail"), findsNothing);
      expect(await io(tester, () => store.entries()), isEmpty);
      // The log is append-only: the memory's line is still there, followed by
      // the tombstone that stands over it.
      expect(
        File("$dir/memories.jsonl").readAsStringSync(),
        contains(entry.id),
      );
    });

    testWidgets("a cancelled confirmation leaves the memory", (tester) async {
      await seed(tester, "a learned detail");
      await open(tester);

      await tester.tap(find.byTooltip("Delete memory"));
      await settleIo(tester);
      await tester.tap(find.widgetWithText(TextButton, "Cancel"));
      await settleIo(tester);

      expect(find.text("a learned detail"), findsOneWidget);
      expect(await io(tester, () => store.entries()), hasLength(1));
    });
  });

  group("pinning", () {
    setUp(start);

    testWidgets("a pin marks the memory and lands in the store", (tester) async {
      final entry = await seed(tester, "the deploy runs on fridays");
      await open(tester);

      await tester.tap(find.byTooltip("Pin: in every turn"));
      await settled(tester);

      final pinned = (await io(tester, () => store.entries())).single;
      expect(pinned.id, entry.id);
      expect(pinned.pinned, isTrue);
      expect(find.textContaining("pinned"), findsOneWidget);
    });

    testWidgets("unpinning takes the mark back", (tester) async {
      final entry = await seed(tester, "the deploy runs on fridays");
      await io(tester, () => store.pin(entry.id));
      await open(tester);

      await tester.tap(find.byTooltip("Unpin"));
      await settled(tester);

      expect((await io(tester, () => store.entries())).single.pinned, isFalse);
    });

    testWidgets("a pin past the limit is refused, the standing four hold",
        (tester) async {
      for (var i = 0; i < pinnedLimit + 1; i++) {
        final entry = await seed(tester, "a standing rule $i");
        await io(tester, () => store.pin(entry.id));
      }
      final unpinned = await seed(tester, "an unpinned memory");
      await open(tester);

      await tester.tap(find.byTooltip("Pin: in every turn"));
      await settleIo(tester);

      expect(find.text("Four is the most that can be pinned."), findsOneWidget);
      final all = await io(tester, () => store.entries());
      expect(all.where((e) => e.id == unpinned.id).single.pinned, isFalse);
    });
  });

  group("search", () {
    setUp(start);

    testWidgets("narrows to the memories its words are in", (tester) async {
      await seed(tester, "the project uses pnpm");
      await seed(tester, "deploy runs on fridays");
      await open(tester);

      await tester.enterText(find.byType(TextField), "deploy");
      await settled(tester);

      expect(find.text("deploy runs on fridays"), findsOneWidget);
      expect(find.text("the project uses pnpm"), findsNothing);
    });

    testWidgets("nothing matching says so rather than showing an empty list",
        (tester) async {
      await seed(tester, "the project uses pnpm");
      await open(tester);

      await tester.enterText(find.byType(TextField), "docker");
      await settled(tester);

      expect(find.text("No memories match"), findsOneWidget);
    });
  });

  group("viewing", () {
    setUp(start);

    testWidgets("tapping a memory shows the whole of it", (tester) async {
      final long = "a fact ${"long enough to be cut off in the list" * 5}";
      await seed(tester, long);
      await open(tester);

      await tester.tap(find.byType(ListTile).first);
      await settleIo(tester);

      final shown = find
          .byWidgetPredicate((w) => w is SelectableText && w.data == long);
      expect(shown, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining("added by you"),
        ),
        findsOneWidget,
      );
    });
  });

  group("getting there", () {
    setUp(start);

    testWidgets("the sidebar opens the default project's memories", (tester) async {
      await seed(tester, "shared by every default-project chat");

      await app.pump(tester, const SizedBox(width: 280, child: Sidebar()));
      await tester.tap(find.byTooltip("Memories"));
      await settleIo(tester);

      expect(find.text("Memories"), findsOneWidget);
      expect(find.textContaining("shared by every default-project chat"), findsOneWidget);
    });

    testWidgets("the project settings page opens the project's own", (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      final projectStore = MemoryStore(
          app.config.fs, app.config.memoryDir(project: "research"));
      await io(tester, () => projectStore.add("research keeps its own"));

      await app.pump(tester, const ProjectSettingsPage(project: "research"));
      await tester.tap(find.widgetWithText(ListTile, "Memories"));
      await settleIo(tester);

      expect(find.text("Project memories"), findsOneWidget);
      expect(find.textContaining("research keeps its own"), findsOneWidget);
    });

    testWidgets("a project can keep its own rather than the default's",
        (tester) async {
      await io(tester, () => app.repo.createProject("research"));

      await app.pump(tester, const ProjectSettingsPage(project: "research"));
      await tester.tap(find.text("Project memory"));
      await settleIo(tester);

      final settings =
          app.container.read(projectSettingsProvider("research"));
      expect(settings.useProjectMemory, isTrue);
    });
  });

  group("the memory category", () {
    late TestApp app;

    setUp(() => app = TestApp.create());
    tearDown(() => app.dispose());

    testWidgets("holds the instructions and the auto-memory sections",
        (tester) async {
      await pumpSettings(tester, app, SettingsCategory.memory);

      expect(find.text("Instructions"), findsOneWidget);
      expect(find.text("Auto memory"), findsOneWidget);
      // The model picker is behind the master: off, it is not drawn.
      expect(find.text("Memory LLM"), findsNothing);
    });

    testWidgets("turning the master on offers the sub-gates and the model",
        (tester) async {
      app.seedSettings(AppSettings(autoMemory: true));
      await pumpSettings(tester, app, SettingsCategory.memory);

      expect(find.text("Keep memories"), findsOneWidget);
      expect(find.text("Recall relevant memories"), findsOneWidget);
      expect(find.text("Write memories after a turn"), findsOneWidget);
      expect(find.text("Memory tools"), findsOneWidget);
      expect(find.text("Memory LLM"), findsOneWidget);
    });

    testWidgets("the sub-gates are dead while the master is off",
        (tester) async {
      app.seedSettings(AppSettings(autoMemory: false, memoryRecall: true));
      await pumpSettings(tester, app, SettingsCategory.memory);

      final switchTile =
          find.widgetWithText(SwitchListTile, "Recall relevant memories");
      expect(tester.widget<SwitchListTile>(switchTile).onChanged, isNull);
      expect(
        app.container.read(appSettingsProvider).memoryRecall,
        isTrue,
        reason: "a dead sub-gate keeps its setting rather than clearing it",
      );
    });
  });
}
