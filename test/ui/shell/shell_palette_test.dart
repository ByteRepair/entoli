import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/shell/shell_palette.dart";
import "package:agent_chat/ui/shell/snapshots.dart";

import "../../harness.dart";

/// The native palette's Dart half: what it lists, how a query narrows it,
/// and what a pick does.
void main() {
  late TestApp app;
  late List<Map<String, Object?>> sent;
  late WidgetRef widgetRef;
  late BuildContext widgetContext;

  setUp(() {
    app = TestApp.create();
    sent = [];
  });
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await app.pump(
      tester,
      ProviderScope(
        overrides: [
          shellOutboxProvider.overrideWithValue(
            ShellOutbox((concern, map) {
              if (concern == "palette") sent.add(map);
            }),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            widgetContext = context;
            return const PalettePublisher();
          },
        ),
      ),
    );
    await io(tester, () async {});
    await settleIo(tester);
  }

  Future<void> run(
    WidgetTester tester,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    await io(
      tester,
      () => runPaletteIntent(widgetContext, widgetRef, ShellIntent(name, args)),
    );
    await settleIo(tester);
  }

  List<Map<Object?, Object?>> items() => [
    for (final section in sent.last["sections"]! as List)
      ...((section as Map)["items"]! as List).cast<Map<Object?, Object?>>(),
  ];

  testWidgets("closed it sends nothing to list; open, projects and chats", (
    tester,
  ) async {
    await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    expect(sent.last["open"], isFalse);

    widgetRef.read(shellPaletteProvider.notifier).open();
    // The chats are read off disk once something is watching them.
    await io(tester, () async {});
    await settleIo(tester);
    expect(sent.last["open"], isTrue);
    final rows = items();
    expect(rows.where((r) => r["chat"] == null), isNotEmpty);
    expect(rows.map((r) => r["label"]), contains("first"));
  });

  testWidgets("a query narrows to what it matches", (tester) async {
    await io(tester, () => app.seedChat(title: "apples"));
    await io(tester, () => app.seedChat(title: "pears"));
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, "search", {"query": "APP"});
    final labels = items().map((r) => r["label"]);
    expect(labels, contains("apples"));
    expect(labels, isNot(contains("pears")));
  });

  testWidgets("picking a chat opens it and closes the palette", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, "pickChat", {"chat": chat.state.id});
    expect(app.container.read(selectedChatIdProvider), chat.state.id);
    expect(sent.last["open"], isFalse);
  });

  testWidgets("picking a project switches to it", (tester) async {
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, "pickProject", {"device": null, "project": "anonymous"});
    expect(app.container.read(selectedProjectProvider).project, "anonymous");
    expect(sent.last["open"], isFalse);
  });
}
