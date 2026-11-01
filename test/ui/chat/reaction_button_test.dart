import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/ui/chat/widgets/reaction_button.dart";

void main() {
  testWidgets("the smiley opens the six reactions, and a pick closes them", (
    tester,
  ) async {
    final picked = <Reaction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReactionButton(onReact: picked.add, onRetract: (_) {}),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip("React"));
    await tester.pumpAndSettle();
    for (final reaction in Reaction.values) {
      expect(find.text(reaction.emoji), findsOneWidget);
    }

    await tester.tap(find.text("👍"));
    await tester.pumpAndSettle();
    expect(picked, [Reaction.thumbsUp]);
    expect(find.text("🔥"), findsNothing);
  });

  testWidgets("a tap outside closes the strip without reacting", (
    tester,
  ) async {
    final picked = <Reaction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReactionButton(onReact: picked.add, onRetract: (_) {}),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip("React"));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text("👍"), findsNothing);
    expect(picked, isEmpty);
  });

  testWidgets("the strip sits just above the button, centred on it", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReactionButton(onReact: (_) {}, onRetract: (_) {}),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip("React"));
    await tester.pumpAndSettle();
    final strip = find.byWidgetPredicate(
      (w) => w is Material && w.elevation == 3,
    );
    final button = tester.getRect(find.byTooltip("React"));
    final popup = tester.getRect(strip);
    expect(popup.center.dx, moreOrLessEquals(button.center.dx));
    expect(popup.bottom, lessThanOrEqualTo(button.top));
    expect(popup.bottom, greaterThan(button.top - 16));
  });

  testWidgets("a chosen emoji is shown chosen, and picking it retracts", (
    tester,
  ) async {
    final reacted = <Reaction>[];
    final retracted = <Reaction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ReactionButton(
              onReact: reacted.add,
              onRetract: retracted.add,
              chosen: const ["🔥"],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip("React"));
    await tester.pumpAndSettle();
    bool chosen(String tip) =>
        tester
            .widget<IconButton>(find.widgetWithText(IconButton, tip))
            .isSelected ??
        false;
    expect(chosen("🔥"), isTrue);
    expect(chosen("👍"), isFalse);

    await tester.tap(find.text("🔥"));
    await tester.pumpAndSettle();
    expect(retracted, [Reaction.fire]);
    expect(reacted, isEmpty);
  });
}
