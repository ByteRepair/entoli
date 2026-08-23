import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/tab_indent.dart";

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TabIndents(
              controller: controller,
              child: TextField(controller: controller),
            ),
            const TextField(key: Key("next")),
          ],
        ),
      ),
    ));
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
  }

  testWidgets("tab types two spaces at the caret", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");
    controller.selection = const TextSelection.collapsed(offset: 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, "he  llo");
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets("tab replaces the selection", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, "h  o");
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets("tab keeps the focus on the field", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, "hello  ");
    // Sending it again would land in the field below if the first had moved on.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(controller.text, "hello    ");
  });

  testWidgets("shift+tab still leaves the field", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, "hello");
  });
}
