import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_slots.dart";
import "package:agent_chat/ui/widgets/liquid_glass.dart";
import "package:agent_chat/ui/widgets/page_bar.dart";

import "fake_native_shell.dart";

/// A page's bar under the native shell: the window's title bar, each action
/// drawn as the system's, and none of it drawn by Flutter.
void main() {
  late FakeNativeShell shell;
  late ProviderContainer container;
  final navigator = GlobalKey<NavigatorState>();

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, {bool glass = true}) async {
    shell = FakeNativeShell.install();
    container = ProviderContainer(
      overrides: [
        liquidGlassProvider.overrideWithValue(
          LiquidGlass(available: true, on: glass),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text("conversation")),
        ),
      ),
    );
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  /// The bar the window's title bar is answering for.
  TitleBarIntents bar() => container.read(shellSlotsProvider).pageBar.top!;

  TitleBarSnapshot sent() => shell.lastPageBar!;
  List<TitleBarItem> items() => sent().items;

  testWidgets("a page's bar is the window's, its tick the confirm", (
    tester,
  ) async {
    var saved = 0;
    await pump(tester);
    await push(
      tester,
      Scaffold(
        appBar: PageBar(
          title: "Chat settings",
          actions: [
            const PageAction.icon(
              icon: Icons.add,
              label: "Add",
              onPressed: null,
            ),
            PageAction.confirm(onPressed: () => saved++),
          ],
        ),
        body: const Text("page"),
      ),
    );
    expect(find.byType(AppBar), findsNothing);
    expect(sent().title, "Chat settings");
    expect(sent().leading, TitleBarLeading.back);
    expect(items().map((i) => (i.symbol, i.style, i.enabled)), [
      ("plus", TitleBarItemStyle.icon, false),
      ("checkmark", TitleBarItemStyle.confirm, true),
    ]);

    await bar().press(items()[1].id);
    expect(saved, 1);
  });

  testWidgets("back pops the page and gives the bar back", (tester) async {
    await pump(tester);
    await push(
      tester,
      const Scaffold(
        appBar: PageBar(title: "Settings"),
        body: Text("settings"),
      ),
    );
    await push(
      tester,
      const Scaffold(
        appBar: PageBar(title: "General"),
        body: Text("general"),
      ),
    );
    expect(sent().title, "General");

    await bar().back();
    await tester.pumpAndSettle();
    expect(find.text("general"), findsNothing);
    expect(sent().title, "Settings");

    await bar().back();
    await tester.pumpAndSettle();
    expect(sent().present, isFalse);
  });

  testWidgets("a discard is a close, a menu its choices", (tester) async {
    var picked = 0;
    await pump(tester);
    await push(
      tester,
      Scaffold(
        appBar: PageBar(
          title: "Edit",
          leading: PageLeading.close,
          actions: [
            PageAction.menu(
              icon: Icons.add,
              label: "Insert",
              items: [
                PageMenuItem(
                  label: "Skill",
                  hint: "/",
                  onSelected: () => picked++,
                ),
                PageMenuItem(label: "Agent", enabled: false, onSelected: () {}),
              ],
            ),
            PageAction.text(label: "Save", onPressed: () {}),
          ],
        ),
        body: const Text("edit"),
      ),
    );
    expect(sent().leading, TitleBarLeading.close);
    final menu = items().first.menu.single;
    expect((menu.label, menu.hint), ("Skill", "/"));
    expect(
      (items().last.label, items().last.style),
      ("Save", TitleBarItemStyle.text),
    );

    await bar().press(menu.id);
    expect(picked, 1);
  });

  testWidgets("without the shell it is an AppBar", (tester) async {
    await pump(tester, glass: false);
    await push(
      tester,
      const Scaffold(
        appBar: PageBar(title: "Settings"),
        body: Text("settings"),
      ),
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text("Settings"), findsOneWidget);
    expect(shell.sent, isEmpty);
  });
}
