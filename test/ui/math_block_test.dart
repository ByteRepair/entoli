import "package:flutter/material.dart";
import "package:flutter_math_fork/flutter_math.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/widgets/markdown_text.dart";

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

  // A parsed tree carries the widget it built, keys and all, so one tree
  // drawn twice failed layout and left the whole chat blank.
  testWidgets("draws the same formula twice in one reply", (tester) async {
    await app.pumpReply(tester, r"inside $D$, since outside $D$ it holds");
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets("draws the same formula in two replies at once", (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [MarkdownText(r"one $x$"), MarkdownText(r"two $x$")],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsNWidgets(2));
  });

  group("selected", () {
    Future<void> dragAll(WidgetTester tester) async {
      final reply = find.byType(MarkdownText);
      await dragCopy(
        tester,
        tester.getTopLeft(reply) + const Offset(2, 4),
        to: tester.getBottomRight(reply) - const Offset(2, 4),
      );
    }

    // A formula is drawn by the maths library, not as text a selection
    // could take a range of, so a drag passed over it and the copy lost it.
    testWidgets("an inline formula is picked up whole, as its TeX", (
      tester,
    ) async {
      final html = <String>[];
      final copied = clipboard(tester, html: html);
      await app.pumpReply(tester, r"inside $D$, since outside $D$ it holds");

      await dragAll(tester);

      expect(copied.single, r"inside $D$, since outside $D$ it holds");
      expect(html.single, contains(r"<p>inside $D$, since outside $D$"));
    });

    testWidgets("a display formula is a block of its own", (tester) async {
      final copied = clipboard(tester);
      await app.pumpReply(tester, "before\n\n\$\$x^2\$\$\n\nafter");

      await dragAll(tester);

      expect(copied.single, "before\n\n\$\$x^2\$\$\n\nafter");
    });

    testWidgets("a formula the drag does not reach is not copied", (
      tester,
    ) async {
      final copied = clipboard(tester);
      await app.pumpReply(tester, r"words first $x$");

      final words = find.textContaining("words", findRichText: true);
      await dragCopy(
        tester,
        tester.getTopLeft(words) + const Offset(1, 4),
        to: tester.getTopLeft(words) + const Offset(40, 4),
      );

      expect(copied.single, isNot(contains(r"$x$")));
    });
  });
}
