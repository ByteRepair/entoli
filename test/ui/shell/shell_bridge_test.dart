import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/app_routes.dart";

import "fake_native_shell.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("the outbox", () {
    test("sends a concern once per change, over the channel", () {
      final shell = FakeNativeShell.install();
      final outbox = ShellOutbox();
      outbox.window(WindowSnapshot(covered: false, sidebarShown: true));
      outbox.window(WindowSnapshot(covered: false, sidebarShown: true));
      expect(shell.sent["window"], hasLength(1));
      outbox.window(
        WindowSnapshot(covered: true, sidebarShown: true, dark: true),
      );
      expect(shell.sent["window"], hasLength(2));
      expect(shell.lastWindow!.covered, isTrue);
      expect(shell.lastWindow!.dark, isTrue);
    });
  });

  testWidgets("a page covers the conversation, and a dialog does not", (
    tester,
  ) async {
    final routes = AppRoutes();
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
    late AppRoutes routes;
    late GlobalKey<NavigatorState> navigator;

    Future<void> pump(WidgetTester tester) async {
      routes = AppRoutes();
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

      final reached = await toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      expect(reached, isTrue);
      expect(routes.depth, 1);
      expect(routes.covered.value, isFalse);
    });

    testWidgets("stops at a page that asks to stay", (tester) async {
      await pump(tester);
      push(const PopScope(canPop: false, child: Text("a prompt")));
      push(const Text("over it"));
      await tester.pumpAndSettle();

      final reached = await toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      expect(reached, isFalse);
      expect(find.text("a prompt"), findsOneWidget);
      expect(routes.depth, 2);
    });

    /// An edited file: back opens "Discard?", which is a route more, and
    /// Discard closes the question and then the page.
    Widget edited() => Builder(
      builder: (page) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final discard = await showDialog<bool>(
            context: page,
            builder: (dialog) => AlertDialog(
              title: const Text("Discard?"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text("Keep"),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text("Discard"),
                ),
              ],
            ),
          );
          if (discard == true && page.mounted) Navigator.pop(page);
        },
        child: const Text("an edited file"),
      ),
    );

    testWidgets("asks a page that asks, and goes on past it on a discard", (
      tester,
    ) async {
      await pump(tester);
      push(const Text("chat settings"));
      push(edited());
      await tester.pumpAndSettle();

      final going = toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      expect(find.text("Discard?"), findsOneWidget);

      await tester.tap(find.text("Discard"));
      await tester.pumpAndSettle();
      expect(await going, isTrue);
      expect(routes.depth, 1);
      expect(find.text("chat settings"), findsNothing);
    });

    testWidgets("stops at a page kept, closing nothing past it", (
      tester,
    ) async {
      await pump(tester);
      push(const Text("chat settings"));
      push(edited());
      await tester.pumpAndSettle();

      final going = toConversation(navigator.currentContext!, routes);
      await tester.pumpAndSettle();
      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();
      expect(await going, isFalse);
      expect(find.text("an edited file"), findsOneWidget);
      expect(routes.depth, 3);
    });
  });
}
