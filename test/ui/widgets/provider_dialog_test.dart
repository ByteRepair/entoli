import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/ui/widgets/provider_dialog.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  late ProviderEdit? returned;

  Future<void> pumpDialog(
    WidgetTester tester, {
    LlmProviderConfig? initial,
    String? storedKey,
    bool encrypted = false,
  }) async {
    // The dialog is taller than the default test window once every field is
    // in it, and the key field is the one below the fold.
    useWindow(tester, const Size(600, 1400));
    returned = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (pageContext) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final result = await promptForProvider(
                    pageContext,
                    initial: initial,
                    storedKey: storedKey,
                    encrypted: encrypted,
                  );
                  returned = result;
                },
                child: const Text("open"),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
  }

  testWidgets(
    "an empty field over no stored key clears, and the text names the store",
    (tester) async {
      await pumpDialog(tester, encrypted: true);
      expect(find.textContaining("OS keyring"), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), "a");
      await tester.enterText(find.byType(TextField).at(1), "https://a.test/v1");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();
      expect(returned!.setKey, "");
    },
  );

  testWidgets("a typed key is a set", (tester) async {
    await pumpDialog(
      tester,
      initial: const LlmProviderConfig(
        id: "a",
        api: LlmApi.openai,
        baseUrl: "https://a.test/v1",
      ),
    );
    await tester.enterText(find.byType(TextField).at(2), "sk-1");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.setKey, "sk-1");
  });

  testWidgets(
    "an empty field over a stored key keeps it, and offers to remove it",
    (tester) async {
      await pumpDialog(
        tester,
        initial: const LlmProviderConfig(
          id: "a",
          api: LlmApi.openai,
          baseUrl: "https://a.test/v1",
        ),
        storedKey: "sk-old",
      );
      expect(find.textContaining("Leave empty to keep"), findsOneWidget);
      expect(find.text("Remove saved key"), findsOneWidget);

      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();
      expect(returned!.setKey, isNull);
    },
  );

  testWidgets("the remove press, then save, clears the stored key", (
    tester,
  ) async {
    await pumpDialog(
      tester,
      initial: const LlmProviderConfig(
        id: "a",
        api: LlmApi.openai,
        baseUrl: "https://a.test/v1",
      ),
      storedKey: "sk-old",
    );

    await tester.tap(find.text("Remove saved key"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.setKey, "");
  });

  testWidgets("the remove press and then typing is a replace, not a remove", (
    tester,
  ) async {
    await pumpDialog(
      tester,
      initial: const LlmProviderConfig(
        id: "a",
        api: LlmApi.openai,
        baseUrl: "https://a.test/v1",
      ),
      storedKey: "sk-old",
    );

    await tester.tap(find.text("Remove saved key"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(2), "sk-new");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(returned!.setKey, "sk-new");
  });

  testWidgets("a stored key is not put back into the field", (tester) async {
    await pumpDialog(
      tester,
      initial: const LlmProviderConfig(
        id: "a",
        api: LlmApi.openai,
        baseUrl: "https://a.test/v1",
      ),
      storedKey: "sk-old",
    );

    final keyField = tester.widget<TextField>(
      find.widgetWithText(TextField, "API key"),
    );
    expect(keyField.controller!.text, isEmpty);
  });

  testWidgets(
    "Claude CLI asks for a program and an environment, not a URL or a key",
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await pumpDialog(tester);
      await tester.enterText(find.byType(TextField).at(0), "Claude");
      await tester.tap(find.text("OpenAI-compatible"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Claude CLI").last);
      await tester.pumpAndSettle();

      expect(find.text("Base URL"), findsNothing);
      expect(find.text("API key"), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, "Executable"),
        "/opt/bin/claude",
      );
      for (final (name, value) in [("A", "1"), ("B", "two=2")]) {
        await tester.ensureVisible(find.text("Add variable"));
        await tester.tap(find.text("Add variable"));
        await tester.pumpAndSettle();
        // The variable's dialog, over the provider's, which has a Name too.
        await tester.enterText(
          find.widgetWithText(TextField, "Name").last,
          name,
        );
        await tester.enterText(find.widgetWithText(TextField, "Value"), value);
        await tester.tap(find.text("Save").last);
        await tester.pumpAndSettle();
      }
      expect(find.text("two=2"), findsNothing, reason: "values are masked");
      await tester.tap(find.text("Save"));
      await tester.pumpAndSettle();

      final config = returned!.config;
      expect(config.api, LlmApi.claudeCli);
      expect(config.command, "/opt/bin/claude");
      expect(config.env, {"A": "1", "B": "two=2"});
      expect(config.defaultModelId, "sonnet");
      expect(returned!.setKey, isNull);
    },
  );
}
