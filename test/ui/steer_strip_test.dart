import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/steer_strip.dart";

void main() {
  final say = Message(
    id: "s1",
    role: MessageRole.user,
    createdAt: DateTime(2026),
    parts: const [MessagePart.text(text: "use the other file")],
  );

  Future<void> pump(WidgetTester tester, {ValueChanged<String>? onWithdraw}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SteerStrip(
              steering: [say], onQueue: (_) {}, onWithdraw: onWithdraw),
        ),
      ));

  testWidgets("a say can be taken back where there is a composer for it",
      (tester) async {
    final withdrawn = <String>[];
    await pump(tester, onWithdraw: withdrawn.add);
    await tester.tap(find.byTooltip("Take back"));
    expect(withdrawn, ["s1"]);
  });

  // The voice screen: taking it back would drop it with nowhere to land.
  testWidgets("no Take back where there is nothing to take it back into",
      (tester) async {
    await pump(tester);
    expect(find.byTooltip("Take back"), findsNothing);
    expect(find.byTooltip("Send after this turn instead"), findsOneWidget);
  });
}
