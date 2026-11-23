import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CodexCliProvider;
import "package:entoli_chat/domain/llm_provider.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/settings/cli_sign_in_dialog.dart";
import "package:agent_chat/ui/settings/settings_category.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  Future<void> pickPreset(WidgetTester tester, String name) async {
    await tester.tap(find.text("Add provider"));
    await settleIo(tester);
    await tester.ensureVisible(find.text(name));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await settleIo(tester);
  }

  testWidgets("a preset's dialog connects it by name, its key focused", (
    tester,
  ) async {
    app = TestApp.create();
    await pumpSettings(tester, app, SettingsCategory.providers);
    await pickPreset(tester, "Ollama Cloud");

    expect(find.text("Connect Ollama Cloud"), findsOneWidget);
    final key = tester.widget<TextField>(
      find.widgetWithText(TextField, "Access key"),
    );
    expect(key.autofocus, isTrue);

    await tester.enterText(find.widgetWithText(TextField, "Access key"), "k1");
    await tester.tap(find.text("Save"));
    await settleIo(tester, least: 3);

    final added = app.container.read(appSettingsProvider).llmProviders.single;
    expect(added.displayName, "Ollama Cloud");
    expect(app.secrets.providerKey(added.id), "k1");
  });

  testWidgets("a free tier is agreed to before anything else is asked", (
    tester,
  ) async {
    app = TestApp.create();
    await pumpSettings(tester, app, SettingsCategory.providers);
    await pickPreset(tester, "Google Gemini");

    expect(find.textContaining("free tier is not private"), findsOneWidget);
    await tester.tap(find.text("Cancel").last);
    await settleIo(tester);
    expect(find.textContaining("Connect Google Gemini"), findsNothing);

    await tester.tap(find.text("Google Gemini"));
    await settleIo(tester);
    await tester.tap(find.text("I understand, add it"));
    await settleIo(tester);
    expect(find.text("Connect Google Gemini"), findsOneWidget);
  });

  testWidgets("a refused key keeps the dialog open, and Save anyway saves", (
    tester,
  ) async {
    app = TestApp.create(acceptsKey: (_) async => false);
    await pumpSettings(tester, app, SettingsCategory.providers);
    await pickPreset(tester, "Ollama Cloud");
    await tester.enterText(find.widgetWithText(TextField, "Access key"), "bad");
    await tester.tap(find.text("Save"));
    await settleIo(tester);

    expect(find.textContaining("did not accept this key"), findsOneWidget);
    expect(app.container.read(appSettingsProvider).llmProviders, isEmpty);

    await tester.tap(find.text("Save anyway"));
    await settleIo(tester, least: 3);
    expect(app.container.read(appSettingsProvider).llmProviders, hasLength(1));
  });

  testWidgets("Remove saved key takes the stored key away", (tester) async {
    app = TestApp.create();
    const box = LlmProviderConfig(
      id: "box",
      api: LlmApi.openai,
      baseUrl: "http://box/v1",
      name: "Box",
    );
    await io(tester, () async {
      await app.seedProviders([box]);
      await app.container
          .read(appSettingsProvider.notifier)
          .upsertProvider(box, setKey: "sk-1");
    });
    await pumpSettings(tester, app, SettingsCategory.providers);

    await tester.tap(find.text("Box"));
    await settleIo(tester);
    expect(find.text("Edit Box"), findsOneWidget);
    await tester.ensureVisible(find.text("Remove saved key"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Remove saved key"));
    await tester.pump();
    await tester.tap(find.text("Save"));
    await settleIo(tester, least: 3);

    expect(app.secrets.providerKey("box"), anyOf(isNull, isEmpty));
  });

  // What the welcome tour's connect is handed: true once the program says
  // it is signed in, false on Cancel with the program stopped.
  testWidgets("a CLI sign-in says whether it took", (tester) async {
    final codex = FakeCli.codex(signedIn: false);
    app = TestApp.create(clis: [FakeCli.claude(), codex]);
    final results = <bool>[];
    await app.pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => results.add(
            await showCliSignIn(
              context,
              CodexCliProvider.preset.copyWith(id: "codex-1"),
            ),
          ),
          child: const Text("Connect"),
        ),
      ),
    );

    await tester.tap(find.text("Connect"));
    await frames(tester);
    expect(find.text("Sign in to ChatGPT"), findsOneWidget);
    await tester.tap(find.text("Cancel"));
    await frames(tester);
    expect(results, [false]);
    await tester.runAsync(() => codex.processes.single.exitCode);

    await tester.tap(find.text("Connect"));
    await frames(tester);
    codex.processes.last.say("https://auth.openai.com/oauth/authorize?x=1");
    codex.finishSignIn();
    await frames(tester);
    expect(results, [false, true]);
    expect(find.text("Sign in to ChatGPT"), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
