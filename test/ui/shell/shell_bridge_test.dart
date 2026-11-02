import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_bridge.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/shell/shell_routes.dart";
import "package:agent_chat/ui/shell/snapshots.dart";

void main() {
  group("the outbox", () {
    test("sends a concern once per change of its map", () {
      final sent = <(String, Map<String, Object?>)>[];
      final outbox = ShellOutbox((concern, map) => sent.add((concern, map)));
      const shown = WindowSnapshot(
        covered: false,
        sidebarShown: true,
        appearance: null,
      );
      outbox.post(shown);
      outbox.post(shown);
      expect(sent, hasLength(1));
      outbox.post(
        const WindowSnapshot(
          covered: true,
          sidebarShown: true,
          appearance: null,
        ),
      );
      expect(sent, hasLength(2));
      expect(sent.last.$1, "window");
      expect(sent.last.$2["covered"], isTrue);
    });
  });

  group("an intent", () {
    test("reads its name and arguments off Swift's map", () {
      final intent = ShellIntent.fromMap({
        "name": "sidebar",
        "args": {"shown": false, "id": "c1", "index": 2.0},
      });
      expect(intent.name, "sidebar");
      expect(intent.flag("shown"), isFalse);
      expect(intent.string("id"), "c1");
      expect(intent.integer("index"), 2);
    });

    test("with no arguments has none", () {
      final intent = ShellIntent.fromMap({"name": "newChat"});
      expect(intent.args, isEmpty);
      expect(intent.flag("anything"), isFalse);
    });
  });

  testWidgets("a page covers the conversation, and a dialog does not", (
    tester,
  ) async {
    final routes = ShellRoutes();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [routes],
        home: const SizedBox(),
      ),
    );
    expect(routes.covered.value, isFalse);

    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const SizedBox(),
    );
    await tester.pumpAndSettle();
    expect(routes.covered.value, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
    );
    await tester.pumpAndSettle();
    expect(routes.covered.value, isTrue);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(routes.covered.value, isFalse);
  });

  group("going back to the conversation", () {
    late ShellRoutes routes;
    late GlobalKey<NavigatorState> navigator;

    Future<void> pump(WidgetTester tester) async {
      routes = ShellRoutes();
      navigator = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [routes],
          home: const SizedBox(),
        ),
      );
    }

    void push(Widget page) => navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page),
    );

    testWidgets("closes every page over it", (tester) async {
      await pump(tester);
      push(const Text("settings"));
      push(const Text("a category"));
      await tester.pumpAndSettle();

      await toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      expect(routes.depth, 1);
      expect(routes.covered.value, isFalse);
    });

    testWidgets("stops at a page that asks to stay", (tester) async {
      await pump(tester);
      push(const PopScope(canPop: false, child: Text("a prompt")));
      push(const Text("over it"));
      await tester.pumpAndSettle();

      await toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      expect(find.text("a prompt"), findsOneWidget);
      expect(routes.depth, 2);
    });
  });

  testWidgets("every tooltip is kept off the toolbar and the composer", (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(shellInsetsProvider).value = const EdgeInsets.only(
      top: 52,
      bottom: 90,
    );
    late EdgeInsetsGeometry? margin;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => ShellInsets(child: child!),
          home: Builder(
            builder: (context) {
              margin = TooltipTheme.of(context).margin;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final resolved = margin!.resolve(TextDirection.ltr);
    expect(resolved.top, 52);
    expect(resolved.bottom, 90);
  });
}
