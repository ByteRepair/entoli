import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/widgets/prompt_field.dart";

void main() {
  Future<List<String>> pump(WidgetTester tester, String value) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptField(
            label: "System prompt",
            value: value,
            hint: "What the agent runs under",
            completions: false,
            onChanged: saved.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return saved;
  }

  testWidgets("the prompt shows rendered, every line of it, with no button", (
    tester,
  ) async {
    await pump(tester, "First line\n\n- one\n- two");

    expect(find.textContaining("First line"), findsOneWidget);
    expect(find.textContaining("two"), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.textContaining("Edit"), findsNothing);
  });

  testWidgets("tapping the preview opens the editor, and saving hands it on", (
    tester,
  ) async {
    final saved = await pump(tester, "Be brief.");

    await tester.tap(find.textContaining("Be brief."));
    await tester.pumpAndSettle();
    expect(find.byType(PromptPage), findsOneWidget);

    await tester.enterText(find.byType(TextField), "Be thorough.");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(saved, ["Be thorough."]);
  });
}
