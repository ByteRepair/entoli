import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";
import "package:flutter_test/flutter_test.dart";
import "package:re_highlight/styles/github-dark.dart";
import "package:re_highlight/styles/github.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/code_block.dart";
import "package:agent_chat/ui/theme.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// A finished reply holding [markdown], which is the only state that renders
  /// it — a streaming one shows raw text.
  Future<void> pump(
    WidgetTester tester,
    String markdown, {
    Brightness brightness = Brightness.light,
  }) =>
      app.pump(
        tester,
        Scaffold(
          body: MessageBubble(
            chatId: "chat-1",
            message: Message(
              id: "m1",
              role: MessageRole.assistant,
              createdAt: DateTime(2026),
              parts: [TextPart(text: markdown)],
            ),
            isWaiting: false,
          ),
        ),
        brightness: brightness,
      );

  CodeBlock block(WidgetTester tester) => tester.widget(find.byType(CodeBlock));

  /// Every colour the highlighted span paints, in the order the code reads.
  /// A span with no style of its own takes its parent's, which is how a token
  /// keeps the monospace font while carrying only a colour.
  List<Color?> colours(InlineSpan span, [Color? inherited]) {
    final own = span.style?.color ?? inherited;
    final found = <Color?>[];
    if (span is TextSpan) {
      if (span.text != null) found.add(own);
      for (final child in span.children ?? const <InlineSpan>[]) {
        found.addAll(colours(child, own));
      }
    }
    return found;
  }

  group("what a fence draws", () {
    testWidgets("the code, without the newline that closed the fence",
        (tester) async {
      await pump(tester, "before\n\n```dart\nvoid main() {}\n```\n\nafter");

      expect(block(tester).code, "void main() {}");
      expect(block(tester).span.toPlainText(), "void main() {}");
    });

    testWidgets("the language it was fenced with, on the block's own bar",
        (tester) async {
      await pump(tester, "```python\nprint(1)\n```");

      expect(block(tester).language, "python");
      expect(find.text("python"), findsOneWidget);
    });

    testWidgets("a fence with no language still draws, and names none",
        (tester) async {
      await pump(tester, "```\nplain\n```");

      expect(block(tester).language, isNull);
      expect(block(tester).code, "plain");
    });

    // An indented block is `pre` with no fence and so no `language-` class.
    testWidgets("an indented block is a block too", (tester) async {
      await pump(tester, "    indented\n");

      expect(block(tester).language, isNull);
      expect(block(tester).code, "indented");
    });

    testWidgets("a long line scrolls rather than wrapping, which would not be "
        "the code that was written", (tester) async {
      await pump(tester, "```bash\n${"echo hello " * 40}\n```");

      final view = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(CodeBlock),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(view.scrollDirection, Axis.horizontal);
    });
  });

  group("highlighting", () {
    testWidgets("a language it knows is coloured token by token", (tester) async {
      await pump(tester, "```dart\nfinal x = 1;\n```");

      final painted = colours(block(tester).span).toSet();
      expect(painted.length, greaterThan(1), reason: "nothing was coloured");
      expect(painted, contains(githubTheme["keyword"]!.color));
    });

    testWidgets("a language it does not know is drawn plain", (tester) async {
      await pump(tester, "```brainfuck\n+[----->+++<]>+.\n```");

      // Not an error and not empty: the code is all there, in one colour.
      expect(block(tester).span.toPlainText(), "+[----->+++<]>+.");
      expect(colours(block(tester).span).toSet().length, 1);
    });

    testWidgets("an alias the grammar declares works like its own name",
        (tester) async {
      await pump(tester, "```sh\nif [ -f x ]; then echo y; fi\n```");

      expect(colours(block(tester).span).toSet().length, greaterThan(1));
    });

    // The token colours are the palette's, not one theme used under both.
    testWidgets("the dark palette gets the dark theme's colours", (tester) async {
      await pump(tester, "```dart\nfinal x = 1;\n```", brightness: Brightness.dark);

      final painted = colours(block(tester).span).toSet();
      expect(painted, contains(githubDarkTheme["keyword"]!.color));
      expect(painted, isNot(contains(githubTheme["keyword"]!.color)));
    });

    // Highlighting the same block again is far more common than it changing:
    // the markdown re-parses on every frame of a palette cross-fade, and
    // scrolling one out of the list and back rebuilds it.
    testWidgets("the same block twice is highlighted once", (tester) async {
      const fence = "```dart\nfinal remembered = 1;\n```";
      await pump(tester, fence);
      final first = block(tester).span;

      await pump(tester, fence);

      expect(identical(block(tester).span, first), isTrue);
    });

    testWidgets("the other palette is not answered out of that", (tester) async {
      const fence = "```dart\nfinal repainted = 1;\n```";
      await pump(tester, fence);
      final light = colours(block(tester).span).toSet();

      await pump(tester, fence, brightness: Brightness.dark);

      expect(colours(block(tester).span).toSet(), isNot(light));
    });

    testWidgets("the code keeps one font whatever it is coloured", (tester) async {
      await pump(tester, "```dart\nfinal x = 1;\n```");

      // A token span carries a colour and nothing else, so anything else it is
      // drawn with has to come from the span above it.
      final span = block(tester).span;
      expect(span.style?.fontFamily, monoFamily);
      for (final child in span.children ?? const <InlineSpan>[]) {
        expect(child.style?.fontFamily, anyOf(isNull, monoFamily));
      }
    });
  });

  group("copying", () {
    testWidgets("the button takes the code, not the fence around it",
        (tester) async {
      final copied = clipboard(tester);
      await pump(tester, "here:\n\n```dart\nvoid main() {}\n```");

      await tester.tap(find.byTooltip("Copy code"));
      await tester.pumpAndSettle();

      expect(copied, ["void main() {}"]);
      expect(find.text("Code copied"), findsOneWidget);
    });

    testWidgets("every block has its own", (tester) async {
      final copied = clipboard(tester);
      await pump(tester, "```dart\nfirst\n```\n\n```dart\nsecond\n```");

      final buttons = find.byTooltip("Copy code");
      expect(buttons, findsNWidgets(2));

      await tester.tap(buttons.last);
      await tester.pumpAndSettle();

      expect(copied, ["second"]);
    });

    // The bar is the block's chrome, not what the model said. Dragging the
    // whole reply still copies its markdown, the language name included in
    // neither direction.
    testWidgets("a drag across the reply does not pick up the bar",
        (tester) async {
      final copied = clipboard(tester);
      const markdown = "read this:\n\n```python\nprint(1)\n```";
      await pump(tester, markdown);

      final reply = find.byType(MarkdownBody);
      final gesture = await tester.startGesture(
        tester.getTopLeft(reply) + const Offset(2, 4),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getBottomRight(reply) - const Offset(2, 4));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(copied, [markdown]);
    });
  });

  // `fromTheme` paints a code block in `cardColor`, which M3 resolves to
  // `colorScheme.surface` — the colour of the page it is drawn on.
  testWidgets("the block is a surface of its own, not the page's",
      (tester) async {
    await pump(tester, "```dart\nvoid main() {}\n```");

    final scheme = Theme.of(tester.element(find.byType(CodeBlock))).colorScheme;
    final decoration = tester
        .widgetList<Container>(
          find.ancestor(of: find.byType(CodeBlock), matching: find.byType(Container)),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>();

    expect(decoration.map((d) => d.color), contains(scheme.surfaceContainer));
    expect(scheme.surfaceContainer, isNot(scheme.surface));
  });
}
