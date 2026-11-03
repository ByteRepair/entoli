import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/shell/shell_slots.dart";
import "package:agent_chat/ui/widgets/liquid_glass.dart";
import "package:agent_chat/ui/widgets/page_bar.dart";

/// A page's bar under the native shell: the window's title bar, each action
/// drawn as the system's, and none of it drawn by Flutter.
void main() {
  late Map<String, Map<String, Object?>> sent;
  late ProviderContainer container;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() => sent = {});
  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, {bool glass = true}) async {
    container = ProviderContainer(
      overrides: [
        liquidGlassProvider.overrideWithValue(
          LiquidGlass(available: true, on: glass),
        ),
        shellOutboxProvider.overrideWithValue(
          ShellOutbox((concern, map) => sent[concern] = map),
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

  Future<void> say(String name, [Map<String, Object?> args = const {}]) =>
      container
          .read(shellSlotsProvider)
          .top(ShellConcern.pageBar)!
          .handle(name, args);

  List<Map<String, Object?>> items() =>
      (sent["pageBar"]!["items"]! as List).cast<Map<String, Object?>>();

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
    expect(sent["pageBar"], containsPair("title", "Chat settings"));
    expect(sent["pageBar"], containsPair("leading", "back"));
    expect(items().map((i) => (i["symbol"], i["style"], i["enabled"])), [
      ("plus", "icon", false),
      ("checkmark", "confirm", true),
    ]);

    await say("press", {"id": items()[1]["id"]});
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
    expect(sent["pageBar"], containsPair("title", "General"));

    await say("back");
    await tester.pumpAndSettle();
    expect(find.text("general"), findsNothing);
    expect(sent["pageBar"], containsPair("title", "Settings"));

    await say("back");
    await tester.pumpAndSettle();
    expect(sent["pageBar"], containsPair("present", false));
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
    expect(sent["pageBar"], containsPair("leading", "close"));
    final menu = (items().first["menu"]! as List).single as Map;
    expect((menu["label"], menu["hint"]), ("Skill", "/"));
    expect((items().last["label"], items().last["style"]), ("Save", "text"));

    await say("press", {"id": menu["id"]});
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
    expect(sent, isEmpty);
  });
}
