import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_bridge.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";
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
}
