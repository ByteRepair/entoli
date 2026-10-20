import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/settings/provider_picker.dart";

void main() {
  testWidgets("fits a phone's width without overflowing", (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickProviderPreset(context, configured: const {}),
            child: const Text("open"),
          ),
        ),
      ),
    ));
    await tester.tap(find.text("open"));
    await tester.pumpAndSettle();

    // An overflow is reported as a test failure on its own; this only checks
    // the picker was drawn at all.
    expect(find.text("Free tier trains on prompts"), findsOneWidget);
  });
}
