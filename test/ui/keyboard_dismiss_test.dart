import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:entoli_chat/ui/widgets/scrolling.dart";

void main() {
  late FocusNode field;
  late int pressed;

  Future<void> pump(WidgetTester tester) async {
    field = FocusNode();
    addTearDown(field.dispose);
    pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: KeyboardDismissOnTouch(
                  child: Center(
                    child: TextButton(
                      onPressed: () => pressed++,
                      child: const Text("Starter"),
                    ),
                  ),
                ),
              ),
              TextField(focusNode: field),
            ],
          ),
        ),
      ),
    );
    field.requestFocus();
    await tester.pump();
    expect(field.hasFocus, isTrue);
  }

  // Off the button, in the empty space above it.
  Offset empty(WidgetTester tester) =>
      tester.getTopLeft(find.byType(KeyboardDismissOnTouch)) +
      const Offset(20, 20);

  testWidgets("a touch on the empty space lowers the keyboard", (tester) async {
    await pump(tester);
    await tester.tapAt(empty(tester));
    await tester.pump();
    expect(field.hasFocus, isFalse);
  });

  testWidgets("a swipe down lowers it too", (tester) async {
    await pump(tester);
    await tester.flingFrom(empty(tester), const Offset(0, 200), 1000);
    await tester.pumpAndSettle();
    expect(field.hasFocus, isFalse);
  });

  testWidgets("what the screen draws keeps its own taps", (tester) async {
    await pump(tester);
    await tester.tap(find.text("Starter"));
    await tester.pump();
    expect(pressed, 1);
  });
}
