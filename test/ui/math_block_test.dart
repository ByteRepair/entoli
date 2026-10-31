import "dart:convert";
import "dart:ui" as ui;

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
      // A word processor gets it drawn, its TeX the picture's alt text.
      expect(
        RegExp(
          r'<img src="data:image/png;base64,[^"]+" alt="\$D\$"',
        ).allMatches(html.single),
        hasLength(2),
      );
    });

    // A paragraph holding a formula answered as one opaque container whose
    // text did not match the paragraph's, and copied with every mark gone.
    testWidgets("the words around a formula keep their formatting", (
      tester,
    ) async {
      final html = <String>[];
      final copied = clipboard(tester, html: html);
      await app.pumpReply(tester, r"some **bold** and `code` with $D$.");

      await dragAll(tester);

      expect(copied.single, r"some **bold** and `code` with $D$.");
      expect(html.single, contains("<b>bold</b>"));
    });

    testWidgets("a display formula is a block of its own", (tester) async {
      final copied = clipboard(tester);
      await app.pumpReply(tester, "before\n\n\$\$x^2\$\$\n\nafter");

      await dragAll(tester);

      expect(copied.single, "before\n\n\$\$x^2\$\$\n\nafter");
    });

    // Black is for what the theme drew, which is white on a dark screen and
    // would vanish on a page; red the TeX asked for is what it meant.
    testWidgets("a formula pastes black, the colours it asked for kept", (
      tester,
    ) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await app.pumpReply(
        tester,
        r"see $\textcolor{red}{x} + y$ here",
        brightness: Brightness.dark,
      );

      await dragAll(tester);

      final colours = await _coloursOf(tester, html.single);
      expect(colours, contains((0, 0, 0)));
      expect(colours, contains((255, 0, 0)));
      expect(colours, isNot(contains((255, 255, 255))));
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

  // The copy button wrote a formula as its TeX, where a selection of the
  // same reply pasted it drawn.
  testWidgets("the copy button pastes a formula drawn, as a selection does", (
    tester,
  ) async {
    final html = <String>[];
    final copied = clipboard(tester, html: html);
    await app.pumpReply(tester, "inside \$D\$\n\n\$\$x^2\$\$");
    await tester.tap(
      find.textContaining("inside", findRichText: true),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip("Copy message"));
    await settleIo(tester);

    expect(copied.single, contains(r"$D$"));
    expect(html.single, contains('alt="\$D\$"'));
    // A formula on a line of its own is centred, as it was drawn.
    expect(
      html.single,
      matches(
        RegExp(r'<p style="text-align: center"><img [^>]*alt="\$\$x\^2\$\$"'),
      ),
    );
  });
}

/// Each fully drawn colour of the picture [html] pastes a formula as.
Future<Set<(int, int, int)>> _coloursOf(
  WidgetTester tester,
  String html,
) async {
  final png = base64Decode(
    RegExp(r'base64,([^"]+)"').firstMatch(html)!.group(1)!,
  );
  final pixels = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return bytes!.buffer.asUint8List();
  });
  return {
    for (var i = 0; i < pixels!.length; i += 4)
      if (pixels[i + 3] == 255) (pixels[i], pixels[i + 1], pixels[i + 2]),
  };
}
