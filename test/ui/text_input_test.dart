import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/text_input.dart";

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  /// The field under a second one, so a Tab that traversed rather than
  /// indented has somewhere to land.
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TabIndents(
              controller: controller,
              child: TextField(controller: controller),
            ),
            const TextField(),
          ],
        ),
      ),
    ));
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
  }

  Future<void> tab(WidgetTester tester, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  testWidgets("tab types two spaces at the caret", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");
    controller.selection = const TextSelection.collapsed(offset: 2);

    await tab(tester);

    expect(controller.text, "he  llo");
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets("tab replaces the selection", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);

    await tab(tester);

    expect(controller.text, "h  o");
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets("a second tab indents again rather than moving on", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");

    await tab(tester);
    await tab(tester);

    expect(controller.text, "hello    ");
  });

  testWidgets("shift+tab still leaves the field", (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, "hello");

    await tab(tester, shift: true);

    expect(controller.text, "hello");
  });

  testWidgets("a field never typed in indents at the end", (tester) async {
    controller.text = "hello";
    await pump(tester);
    controller.selection = const TextSelection.collapsed(offset: -1);

    await tab(tester);

    expect(controller.text, "hello  ");
  });
}
