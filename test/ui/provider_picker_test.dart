import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/ui/settings/provider_picker.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart"
    show CliProvider, HostCliGuest;

void main() {
  testWidgets("fits a phone's width without overflowing", (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickProviderPreset(context),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();

    // An overflow is reported as a test failure on its own; this only checks
    // the picker was drawn at all.
    expect(find.text("Free tier trains on prompts"), findsOneWidget);
  });

  testWidgets("offers Claude CLI on a desktop, opening on its own fields", (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    ({LlmProviderConfig? preset})? picked;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await pickProviderPreset(context),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text("Claude CLI"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Claude CLI"));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    expect(picked!.preset!.api, LlmApi.claudeCli);
  });

  // An Android build with no proot has nowhere to run the program.
  testWidgets("offers no Claude CLI where it has nowhere to run", (
    tester,
  ) async {
    CliProvider.platformGuest = null;
    addTearDown(() => CliProvider.platformGuest = const HostCliGuest());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickProviderPreset(context),
              child: const Text("open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();
    expect(find.text("Claude CLI"), findsNothing);
  });
}
