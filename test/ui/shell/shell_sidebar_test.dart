import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/shell/shell_sidebar.dart";
import "package:agent_chat/ui/shell/snapshots.dart";

import "../../harness.dart";

void main() {
  late TestApp app;
  late List<Map<String, Object?>> sidebars;
  late WidgetRef widgetRef;
  late BuildContext widgetContext;

  setUp(() {
    app = TestApp.create();
    sidebars = [];
  });
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await app.pump(
      tester,
      ProviderScope(
        overrides: [
          shellOutboxProvider.overrideWithValue(
            ShellOutbox((concern, map) {
              if (concern == "sidebar") sidebars.add(map);
            }),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            widgetContext = context;
            return const SidebarPublisher();
          },
        ),
      ),
    );
    // The chat list is read off disk; let it land.
    await io(tester, () async {});
    await settleIo(tester);
  }

  List<String> titles() => [
    for (final group in sidebars.last["groups"]! as List<Object?>)
      for (final row in (group! as Map)["rows"] as List<Object?>)
        (row! as Map)["title"] as String,
  ];

  Future<void> run(WidgetTester tester, ShellIntent intent) async {
    await io(tester, () => runSidebarIntent(widgetContext, widgetRef, intent));
    await settleIo(tester);
  }

  testWidgets("lists the project's chats under their headings", (tester) async {
    await io(tester, () => app.seedChat(title: "first"));
    await io(tester, () => app.seedChat(title: "second"));
    await pump(tester);
    expect(titles(), containsAll(["first", "second"]));
    expect(sidebars.last["empty"], isNull);
    final groups = sidebars.last["groups"]! as List<Object?>;
    expect((groups.first! as Map)["heading"], isNotEmpty);
  });

  testWidgets("an empty project says so", (tester) async {
    await pump(tester);
    expect(titles(), isEmpty);
    expect(sidebars.last["empty"], "No chats in this project yet.");
  });

  testWidgets("a search narrows the rows, and switching project clears it", (
    tester,
  ) async {
    await io(tester, () => app.seedChat(title: "apples"));
    await io(tester, () => app.seedChat(title: "pears"));
    await pump(tester);

    await run(tester, const ShellIntent("search", {"query": "APP"}));
    expect(titles(), ["apples"]);
    expect(sidebars.last["query"], "APP");

    await run(
      tester,
      const ShellIntent("selectProject", {"device": null, "project": "x"}),
    );
    expect(sidebars.last["query"], "");
  });

  testWidgets("opening a row selects it, and new chat selects nothing", (
    tester,
  ) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);

    await run(tester, ShellIntent("openChat", {"id": chat.state.id}));
    expect(app.container.read(selectedChatIdProvider), chat.state.id);
    expect(sidebars.last["selected"], chat.state.id);

    await run(tester, const ShellIntent("newChat"));
    expect(app.container.read(selectedChatIdProvider), isNull);
  });

  testWidgets("pin, rename and delete write the chat", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    final id = chat.state.id;

    await run(tester, ShellIntent("pin", {"id": id, "pinned": true}));
    final pinned = sidebars.last["groups"]! as List<Object?>;
    expect((pinned.first! as Map)["heading"], "Pinned");

    await run(tester, ShellIntent("rename", {"id": id, "title": "renamed"}));
    expect(titles(), ["renamed"]);

    await run(tester, ShellIntent("delete", {"id": id}));
    expect(titles(), isEmpty);
  });

  testWidgets("a name no project can have is refused with a reason", (
    tester,
  ) async {
    await pump(tester);
    final answer = await runSidebarIntent(
      widgetContext,
      widgetRef,
      const ShellIntent("createProject", {"name": "   "}),
    );
    expect(answer, isA<String>());
  });
}
