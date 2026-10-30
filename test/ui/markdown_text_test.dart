import "package:flutter/material.dart";
import "package:flutter_math_fork/flutter_math.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/chat/widgets/code_block.dart";
import "package:agent_chat/ui/chat/widgets/markdown_text.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pump(
    WidgetTester tester,
    String markdown, {
    ValueChanged<String>? onTapLink,
  }) => app.pump(
    tester,
    Scaffold(body: MarkdownText(markdown, onTapLink: onTapLink)),
  );

  // Outside a reply, which is the point of it being one widget.
  testWidgets("draws formulas and code blocks wherever it is", (tester) async {
    await pump(tester, "\$\$x^2\$\$\n\n```dart\nvoid main() {}\n```");
    expect(find.byType(Math), findsOneWidget);
    expect(find.byType(CodeBlock), findsOneWidget);
  });

  testWidgets("numbers a numbered list and bullets the rest", (tester) async {
    await pump(tester, "1. one\n2. two\n\n- three");
    expect(find.text("1."), findsOneWidget);
    expect(find.text("2."), findsOneWidget);
    expect(find.text("•"), findsOneWidget);
  });

  testWidgets("reports a tapped link's target", (tester) async {
    final tapped = <String>[];
    await pump(tester, "[here](https://example.com)", onTapLink: tapped.add);
    await tester.tap(find.text("here", findRichText: true));
    expect(tapped, ["https://example.com"]);
  });
}
