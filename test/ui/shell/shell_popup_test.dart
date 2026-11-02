import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/ui/chat/widgets/reaction_button.dart";
import "package:agent_chat/ui/widgets/liquid_glass.dart";

/// The reaction strip under the native shell: asked of the Swift, where the
/// button is, and answered with what was picked.
void main() {
  late List<Map<Object?, Object?>> asked;

  setUp(() => asked = []);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shellChannel, null),
  );

  /// The Swift, answering every strip with [answer].
  void swiftAnswers(int? answer) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(shellChannel, (call) async {
        if (call.method == "strip") {
          asked.add(call.arguments as Map<Object?, Object?>);
          return answer;
        }
        return null;
      });

  Future<List<Reaction>> pump(
    WidgetTester tester, {
    List<String> chosen = const [],
  }) async {
    final reacted = <Reaction>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liquidGlassProvider.overrideWithValue(
            const LiquidGlass(available: true, on: true),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReactionButton(onReact: reacted.add, chosen: chosen),
            ),
          ),
        ),
      ),
    );
    return reacted;
  }

  testWidgets("the shell is asked at the button, and its pick reacts", (
    tester,
  ) async {
    swiftAnswers(2);
    final reacted = await pump(tester, chosen: [Reaction.thumbsUp.emoji]);
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();

    final strip = asked.single;
    final button = tester.getRect(find.byType(ReactionButton));
    expect(strip["x"], button.left);
    expect(strip["y"], button.top);
    final choices = (strip["choices"]! as List).cast<Map<Object?, Object?>>();
    expect(choices.map((c) => c["glyph"]), [
      for (final r in Reaction.values) r.emoji,
    ]);
    expect(choices.first["chosen"], isTrue);
    expect(reacted, [Reaction.values[2]]);
    expect(find.byType(IconButton), findsOneWidget, reason: "no Flutter strip");
  });

  testWidgets("a strip dismissed reacts with nothing", (tester) async {
    swiftAnswers(null);
    final reacted = await pump(tester);
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();
    expect(reacted, isEmpty);
  });
}
