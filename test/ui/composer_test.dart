import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/widgets/composer.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  final controller = TextEditingController();
  final sent = <String>[];

  setUp(() {
    app = TestApp.create();
    controller.clear();
    sent.clear();
  });
  tearDown(() => app.dispose());
  tearDownAll(controller.dispose);

  Future<void> pump(WidgetTester tester) => app.pump(
        tester,
        Scaffold(
          body: Composer(
            chatId: "chat-1",
            controller: controller,
            isRunning: false,
            onSend: sent.add,
            onAbort: () {},
          ),
        ),
      );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  /// The names the menu is offering, in order — the descriptions beside them
  /// carry no trigger character.
  List<String> menuItems(WidgetTester tester) => popupLabels(tester)
      .nonNulls
      .where((s) => s.startsWith("/") || s.startsWith("@"))
      .toList();

  testWidgets("typing / offers every command", (tester) async {
    await pump(tester);
    await type(tester, "/");

    expect(menuItems(tester), ["/init", "/review", "/revert"]);
  });

  testWidgets("typing narrows the menu to what matches", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    expect(menuItems(tester), ["/review", "/revert"]);
  });

  testWidgets("a query that matches nothing closes the menu", (tester) async {
    await pump(tester);
    await type(tester, "/zzz");

    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("typing @ offers agents instead", (tester) async {
    await pump(tester);
    await type(tester, "@");

    expect(menuItems(tester), ["@build", "@explore"]);
  });

  testWidgets("@ works mid-message, / only at the start", (tester) async {
    await pump(tester);

    await type(tester, "have @exp");
    expect(menuItems(tester), ["@explore"]);

    await type(tester, "see /rev");
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("tapping an entry completes it and closes the menu", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.tap(find.text("/revert"));
    await tester.pumpAndSettle();

    expect(controller.text, "/revert ");
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("a completed mention keeps what came before it", (tester) async {
    await pump(tester);
    await type(tester, "ask @exp");

    await tester.tap(find.text("@explore"));
    await tester.pumpAndSettle();

    expect(controller.text, "ask @explore ");
  });

  testWidgets("arrows move the highlight and enter takes it", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "/review ");
    expect(sent, isEmpty);
  });

  testWidgets("the highlight wraps past the end of the list", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "/revert ");
  });

  testWidgets("escape closes the menu and hands enter back to the field", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, "/rev");
  });

  // The test harness never turns a key event into typed text, so this can only
  // show that enter was left to the field, not the newline it produces there.
  testWidgets("with no menu open, enter belongs to the field", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "hello");
    expect(sent, isEmpty);
  });

  testWidgets("ctrl+enter still sends", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(sent, ["hello"]);
    expect(controller.text, isEmpty);
  });

  Future<void> insertVia(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets("the + button's Commands entry opens the command menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Commands");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/review", "/revert"]);
  });

  testWidgets("the + button's Agents entry opens the agent menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Agents");

    expect(controller.text, "@");
    expect(menuItems(tester), ["@build", "@explore"]);
  });

  testWidgets("a command goes to the start of the message, a mention to the caret",
      (tester) async {
    await pump(tester);
    await type(tester, "look here");

    await insertVia(tester, "Agents");
    expect(controller.text, "look here @");

    await insertVia(tester, "Commands");
    expect(controller.text, "/look here @");
  });

  testWidgets("asking for commands twice does not stack up slashes", (tester) async {
    await pump(tester);
    await insertVia(tester, "Commands");
    await insertVia(tester, "Commands");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/review", "/revert"]);
  });

  testWidgets("the + button reopens a menu that was dismissed", (tester) async {
    await pump(tester);
    await type(tester, "/");
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);

    await insertVia(tester, "Commands");

    expect(menuItems(tester), ["/init", "/review", "/revert"]);
  });

  testWidgets("the menu says so while the list is still loading", (tester) async {
    app.backend.holdCompletions = Completer<void>();
    await pump(tester);
    await type(tester, "/");

    expect(find.text("Loading commands..."), findsOneWidget);

    app.backend.holdCompletions!.complete();
    await tester.pumpAndSettle();
    expect(menuItems(tester), ["/init", "/review", "/revert"]);
  });

  testWidgets("a backend with nothing to offer opens no menu", (tester) async {
    app.backend.scriptedCompletions = const {};
    await pump(tester);
    await type(tester, "/");

    expect(find.byType(ListView), findsNothing);
  });
}
