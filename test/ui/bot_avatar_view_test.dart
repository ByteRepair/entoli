import "package:agent_chat/domain/bot_avatar/definition.dart";
import "package:agent_chat/domain/bot_avatar/spec.dart";
import "package:agent_chat/ui/bot_avatar/bot_avatar_view.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

final _spec = BotAvatarSpec(
  definition:
      (BotAvatarDefinition.validate({
                "version": 1,
                "id": "box",
                "name": "Box",
                "body": {"path": "M20 20 H80 V80 H20 Z"},
                "eyes": {"x": 50, "y": 46, "spacing": 15, "scale": 1},
              })
              as BotAvatarValid)
          .definition,
  colour: 0x1fbf68,
);

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The avatar's ticker is the only one on screen, so a transient callback is
/// its ticker running.
bool _ticking(WidgetTester tester) => tester.binding.transientCallbackCount > 0;

void main() {
  group("BotAvatarView", () {
    testWidgets("an avatar that is not painted stops, and starts on paint", (
      tester,
    ) async {
      Widget at({required bool hidden}) => _app(
        Offstage(
          offstage: hidden,
          child: BotAvatarView(spec: _spec, size: 48),
        ),
      );
      await tester.pumpWidget(at(hidden: false));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_ticking(tester), isTrue);

      await tester.pumpWidget(at(hidden: true));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_ticking(tester), isFalse, reason: "nothing drawn, nothing run");

      await tester.pumpWidget(at(hidden: false));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_ticking(tester), isTrue);
    });

    testWidgets("a row built past the viewport sleeps until scrolled to", (
      tester,
    ) async {
      final scroll = ScrollController();
      await tester.pumpWidget(
        _app(
          ListView(
            controller: scroll,
            cacheExtent: 2000,
            children: [
              const SizedBox(height: 1500),
              BotAvatarView(spec: _spec, size: 48),
            ],
          ),
        ),
      );
      expect(
        find.byType(BotAvatarView, skipOffstage: false),
        findsOneWidget,
        reason: "built, in the cache extent",
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_ticking(tester), isFalse);

      scroll.jumpTo(1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(_ticking(tester), isTrue);
    });
  });
}
