import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  final field = find.byType(TextField);
  final reply = find.byType(SelectableText);

  /// A field to type in and a reply to select text in, which is the chat page in
  /// the two parts that matter here.
  Future<void> pump(WidgetTester tester) => app.pump(
        tester,
        Scaffold(
          body: Column(
            children: [
              const SelectableText("a reply"),
              TextField(controller: TextEditingController()),
            ],
          ),
        ),
      );

  testWidgets("the caret goes when the keyboard does", (tester) async {
    await pump(tester);
    await tester.tap(field);
    await softKeyboard(tester, up: true);
    expect(holdsCaret(tester, field), isTrue);

    await softKeyboard(tester, up: false);

    expect(holdsCaret(tester, field), isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets("a field the keyboard was never up for is left alone", (tester) async {
    await pump(tester);
    await tester.tap(field);
    await settleIo(tester);
    expect(holdsCaret(tester, field), isTrue);

    // Insets that were never raised: nothing was taken away, so there is nothing
    // to answer for.
    await softKeyboard(tester, up: false);

    expect(holdsCaret(tester, field), isTrue);
  });

  testWidgets("a selection made while the keyboard was up keeps it", (tester) async {
    await pump(tester);
    await tester.tap(field);
    await softKeyboard(tester, up: true);

    // Selecting text in a reply takes the focus and so closes the keyboard. What
    // it took is not the keyboard's to give back.
    await tester.tap(reply);
    await settleIo(tester);
    await softKeyboard(tester, up: false);

    expect(holdsCaret(tester, reply), isTrue);
    expect(holdsCaret(tester, field), isFalse);
  });
}
