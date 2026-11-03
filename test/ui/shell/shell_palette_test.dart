import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_palette.dart";

import "../../harness.dart";
import "fake_native_shell.dart";

/// The native palette's Dart half: what it lists, how a query narrows it,
/// and what a pick does.
void main() {
  late TestApp app;
  late FakeNativeShell shell;
  late WidgetRef widgetRef;
  late PaletteRunner palette;

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
            widgetRef = ref;
            palette = PaletteRunner(context, ref);
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
    FutureOr<void> Function(PaletteRunner) intent,
  ) async {
    await io(tester, () async => intent(palette));
    await settleIo(tester);
  }

  PaletteSnapshot last() => shell.lastPalette!;

  List<PaletteItem> items() => [
    for (final section in last().sections) ...section.items,
  ];

  testWidgets("closed it sends nothing to list; open, projects and chats", (
    tester,
  ) async {
    await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    expect(last().open, isFalse);

    widgetRef.read(shellPaletteProvider.notifier).open();
    // The chats are read off disk once something is watching them.
    await io(tester, () async {});
    await settleIo(tester);
    expect(last().open, isTrue);
    final rows = items();
    expect(rows.where((r) => r.chat == null), isNotEmpty);
    expect(rows.map((r) => r.label), contains("first"));
  });

  testWidgets("a query narrows to what it matches", (tester) async {
    await io(tester, () => app.seedChat(title: "apples"));
    await io(tester, () => app.seedChat(title: "pears"));
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, (p) => p.search("APP"));
    final labels = items().map((r) => r.label);
    expect(labels, contains("apples"));
    expect(labels, isNot(contains("pears")));
  });

  testWidgets("picking a chat opens it and closes the palette", (tester) async {
    final chat = await io(tester, () => app.seedChat(title: "first"));
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, (p) => p.pickChat(chat.state.id));
    expect(app.container.read(selectedChatIdProvider), chat.state.id);
    expect(last().open, isFalse);
  });

  testWidgets("picking a project switches to it", (tester) async {
    await pump(tester);
    widgetRef.read(shellPaletteProvider.notifier).open();
    await settleIo(tester);

    await run(tester, (p) => p.pickProject(null, "anonymous"));
    expect(app.container.read(selectedProjectProvider).project, "anonymous");
    expect(last().open, isFalse);
  });
}
