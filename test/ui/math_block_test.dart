import "package:flutter/material.dart";
import "package:flutter_math_fork/flutter_math.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  testWidgets("draws a display formula rather than its source", (tester) async {
    await app.pumpReply(tester, r"$$\frac{a}{b}$$");
    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining("frac"), findsNothing);
  });

  testWidgets("sets an inline formula inside its sentence", (tester) async {
    await app.pumpReply(tester, r"the area is $\pi r^2$ exactly");
    expect(find.byType(Math), findsOneWidget);
    // One paragraph: the formula is a span of it, not a widget beside it.
    expect(find.textContaining("the area is", findRichText: true), findsOne);
    expect(find.textContaining("exactly", findRichText: true), findsOne);
    final paragraph = tester.widget<RichText>(
      find.textContaining("the area is", findRichText: true),
    );
    expect(paragraph.text.toPlainText(), contains("exactly"));
  });

  testWidgets("shows TeX it cannot parse as it was written", (tester) async {
    await app.pumpReply(tester, r"$$\frac{a$$");
    expect(find.textContaining(r"\frac{a"), findsOneWidget);
  });
}
