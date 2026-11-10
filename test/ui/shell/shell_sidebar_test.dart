import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_publisher.dart";
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
    final publisher = ShellPublisher(app.container);
    addTearDown(publisher.close);
    await app.pump(
      tester,
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            sidebar = SidebarRunner(context, ref);
            return const SizedBox.shrink();
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
    FutureOr<void> Function(SidebarRunner) intent,
  ) async {
    await io(tester, () async => intent(sidebar));
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

    // Each edit writes the chat and then re-reads the list off disk, which is
    // real I/O no fixed count of rounds outlasts on a loaded runner: wait for
    // what the snapshot is meant to say, not for the tree to look idle.
    await run(tester, (s) => s.pin(id, true));
    await settleUntil(
      tester,
      () => last().groups.first.heading == "Pinned",
      what: "the Pinned heading",
    );

    await run(tester, (s) => s.rename(id, "renamed"));
    await settleUntil(
      tester,
      () => titles().join() == "renamed",
      what: "the new title",
    );

    await run(tester, (s) => s.delete(id));
    await settleUntil(tester, () => titles().isEmpty, what: "the row gone");
  });

  testWidgets("a change reaches the sidebar with no frame drawn", (
    tester,
  ) async {
    await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    // An iPhone showing the list has the Flutter view out of the window and
    // the engine paused: nothing is drawn until the user leaves the list.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    final query = await tester.runAsync(() {
      final arrived = shell.next<SidebarSnapshot>(
        "sidebar",
        (s) => s.query == "fir",
      );
      sidebar.search("fir");
      // Only so the old failure says what it is rather than hanging.
      return arrived.timeout(const Duration(seconds: 10));
    });
    expect(query!.query, "fir");
  });

  testWidgets("a name no project can have is refused with a reason", (
    tester,
  ) async {
    await pump(tester);
    final answer = await sidebar.createProject("   ", "", false);
    expect(answer, isA<String>());
  });
}
