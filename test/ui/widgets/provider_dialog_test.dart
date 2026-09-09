import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/ui/widgets/provider_dialog.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

/// What the dialog answered, read back out of the snack bar it raised:
/// "set:sk-1", "keep:-", "clear:-", "dismissed".
String answer(WidgetTester tester) => tester.widget<Text>(find.descendant(
        of: find.byType(SnackBar), matching: find.byType(Text)))
    .data!;

void main() {
  late ProviderEdit? returned;

  Future<void> pumpDialog(WidgetTester tester,
      {LlmProviderConfig? initial, String? storedKey, bool encrypted = false}) async {
    // The dialog is taller than the default test window once every field is
    // in it, and the key field is the one below the fold.
    useWindow(tester, const Size(600, 1400));
    returned = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (pageContext) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await promptForProvider(pageContext,
                    initial: initial, storedKey: storedKey, encrypted: encrypted);
                returned = result;
              },
              child: const Text("open"),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  testWidgets("an empty field over no stored key clears, and the text names the store",
      (tester) async {
    await pumpDialog(tester, encrypted: true);
    expect(find.textContaining("OS keyring"), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), "a");
    await tester.enterText(find.byType(TextField).at(1), "https://a.test/v1");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.key, KeyChange.clear);
  });

  testWidgets("a typed key is a set", (tester) async {
    await pumpDialog(tester,
        initial: const LlmProviderConfig(
          id: "a", api: LlmApi.openai, baseUrl: "https://a.test/v1",
        ));
    await tester.enterText(find.byType(TextField).at(2), "sk-1");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.key, KeyChange.set);
    expect(returned!.typedKey, "sk-1");
  });

  testWidgets("an empty field over a stored key keeps it, and offers to remove it",
      (tester) async {
    await pumpDialog(tester,
        initial: const LlmProviderConfig(
          id: "a", api: LlmApi.openai, baseUrl: "https://a.test/v1",
        ), storedKey: "sk-old");
    expect(find.textContaining("Leave empty to keep"), findsOneWidget);
    expect(find.text("Remove stored key"), findsOneWidget);

    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.key, KeyChange.keep);
  });

  testWidgets("the remove press, then save, clears the stored key", (tester) async {
    await pumpDialog(tester,
        initial: const LlmProviderConfig(
          id: "a", api: LlmApi.openai, baseUrl: "https://a.test/v1",
        ), storedKey: "sk-old");

    await tester.tap(find.text("Remove stored key"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.key, KeyChange.clear);
  });

  testWidgets("the remove press and then typing is a replace, not a remove",
      (tester) async {
    await pumpDialog(tester,
        initial: const LlmProviderConfig(
          id: "a", api: LlmApi.openai, baseUrl: "https://a.test/v1",
        ), storedKey: "sk-old");

    await tester.tap(find.text("Remove stored key"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), "sk-new");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.key, KeyChange.set);
    expect(returned!.typedKey, "sk-new");
  });

  testWidgets("a stored key is not put back into the field", (tester) async {
    await pumpDialog(tester,
        initial: const LlmProviderConfig(
          id: "a", api: LlmApi.openai, baseUrl: "https://a.test/v1",
        ), storedKey: "sk-old");

    final keyField =
        tester.widget<TextField>(find.widgetWithText(TextField, "API key"));
    expect(keyField.controller!.text, isEmpty);
  });
}