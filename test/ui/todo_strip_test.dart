import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/todo.dart";
import "package:agent_chat/ui/chat/widgets/todo_strip.dart";

import "../harness.dart";

void main() {
  const list = TodoList([
    TodoItem("Read the parser", TodoStatus.completed),
    TodoItem("Fix the header", TodoStatus.inProgress),
    TodoItem("Run the tests", TodoStatus.pending),
  ]);

  testWidgets("the strip says how far the list is and opens to every task", (
    tester,
  ) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    await app.pump(tester, const Scaffold(body: TodoStrip(list: list)));

    expect(find.text("1/3  "), findsOneWidget);
    expect(find.text("Fix the header"), findsOneWidget);
    expect(find.text("Run the tests"), findsNothing);

    await tester.tap(find.text("Fix the header"));
    await tester.pumpAndSettle();

    expect(find.text("Read the parser"), findsOneWidget);
    expect(find.text("Run the tests"), findsOneWidget);
  });

  testWidgets("no list draws nothing", (tester) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    await app.pump(tester, const Scaffold(body: TodoStrip(list: null)));

    expect(find.byIcon(Icons.checklist), findsNothing);
  });
}
