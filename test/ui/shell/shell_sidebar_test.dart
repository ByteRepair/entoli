import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_sidebar.dart";

import "../../harness.dart";
import "fake_native_shell.dart";

void main() {
  late TestApp app;
  late FakeNativeShell shell;
  late SidebarRunner sidebar;

  setUp(() {
    app = TestApp.create();
    shell = FakeNativeShell.install();
  });
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await app.pump(
      tester,
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            sidebar = SidebarRunner(context, ref);
            return const SidebarPublisher();
          },
        ),
      ),
    );
    // The chat list is read off disk; let it land.
    await io(tester, () async {});
    await settleIo(tester);
  }

  SidebarSnapshot last() => shell.lastSidebar!;

  List<String> titles() => [
    for (final group in last().groups)
      for (final row in group.rows) row.title,
  ];

  Future<void> run(
    WidgetTester tester,
    Future<void> Function(SidebarRunner) intent,
  ) async {
    await io(tester, () => intent(sidebar));
    await settleIo(tester);
  }

  testWidgets("lists the project's chats under their headings", (tester) async {
    await io(tester, () => app.seedChat(title: "first"));
    await io(tester, () => app.seedChat(title: "second"));
    await pump(tester);
    expect(titles(), containsAll(["first", "second"]));
    expect(last().empty, isNull);
    expect(last().groups.first.heading, isNotEmpty);
  });

  testWidgets("an empty project says so", (tester) async {
    await pump(tester);
    expect(titles(), isEmpty);
    expect(last().empty, "No chats in this project yet.");
  });

  testWidgets("a search narrows the rows, and switching project clears it", (
    tester,
  ) async {
    await io(tester, () => app.seedChat(title: "apples"));
    await io(tester, () => app.seedChat(title: "pears"));
    await pump(tester);

    await run(tester, (s) => s.search("APP"));
    expect(titles(), ["apples"]);
    expect(last().query, "APP");

    await run(tester, (s) => s.selectProject(null, "x"));
    expect(last().query, "");
  });

  testWidgets("opening a row selects it, and new chat selects nothing", (
    tester,
  ) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);

    await run(tester, (s) => s.openChat(chat.state.id));
    expect(app.container.read(selectedChatIdProvider), chat.state.id);
    expect(last().selected, chat.state.id);

    await run(tester, (s) => s.newChat());
    expect(app.container.read(selectedChatIdProvider), isNull);
  });

  testWidgets("pin, rename and delete write the chat", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    final id = chat.state.id;

    await run(tester, (s) => s.pin(id, true));
    expect(last().groups.first.heading, "Pinned");

    await run(tester, (s) => s.rename(id, "renamed"));
    expect(titles(), ["renamed"]);

    await run(tester, (s) => s.delete(id));
    expect(titles(), isEmpty);
  });

  testWidgets("a name no project can have is refused with a reason", (
    tester,
  ) async {
    await pump(tester);
    final answer = await sidebar.createProject("   ", "", false);
    expect(answer, isA<String>());
  });
}
