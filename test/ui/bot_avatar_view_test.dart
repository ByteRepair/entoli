import "dart:math" as math;

import "package:agent_chat/domain/bot_avatar/animation.dart";
import "package:agent_chat/domain/bot_avatar/definition.dart";
import "package:agent_chat/domain/bot_avatar/frame.dart";
import "package:agent_chat/domain/bot_avatar/pose.dart";
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

/// A random source that always draws [value].
class _Fixed implements math.Random {
  _Fixed(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The avatar's ticker is the only one on screen, so a transient callback is
/// its ticker running.
bool _ticking(WidgetTester tester) => tester.binding.transientCallbackCount > 0;

void main() {
  group("BotAnimation", () {
    test("a tap is happy for five seconds, and spins under the chance", () {
      final calm = BotAnimation.tapped(_Fixed(0.5));
      expect(calm.mood, BotMood.happy);
      expect(calm.duration, const Duration(seconds: 5));
      expect(calm.spin, isFalse);
      expect(BotAnimation.tapped(_Fixed(0.1)).spin, isTrue);
    });

    test("a spin is one full turn that ends where it began", () {
      const spin = BotAnimation(
        mood: BotMood.happy,
        duration: Duration(seconds: 5),
        spin: true,
      );
      final mid =
          BotAnimation.spinStart +
          Duration(microseconds: BotAnimation.spinLength.inMicroseconds ~/ 2);
      expect(spin.yawAt(Duration.zero), 0);
      expect(spin.yawAt(mid), closeTo(math.pi, 1e-9));
      expect(spin.yawAt(const Duration(seconds: 3)), 0);
      expect(
        BotAnimation(mood: BotMood.happy, duration: spin.duration).yawAt(mid),
        0,
      );
    });
  });

  group("BotAvatarView", () {
    testWidgets("a tap is happy for five seconds, then back to its mood", (
      tester,
    ) async {
      /// Happy eyes are arcs; every other mood's are pills.
      bool happy() {
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(BotAvatarView),
            matching: find.byType(CustomPaint),
          ),
        );
        final frame = (paint.painter! as BotAvatarPainter).frame.value;
        return frame.shapes.any((s) => s is EyeShapeMark && s.mark is ArcMark);
      }

      await tester.pumpWidget(
        _app(
          Center(child: BotAvatarView(spec: _spec, size: 48, reactToTap: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(happy(), isFalse);

      await tester.tap(find.byType(BotAvatarView));
      // Past the mood change's ease.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(happy(), isTrue);

      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(happy(), isFalse);
      expect(tester.takeException(), isNull);
    });

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

    testWidgets("following a touch draws without error", (tester) async {
      await tester.pumpWidget(
        _app(
          Align(
            alignment: Alignment.topLeft,
            child: BotAvatarView(spec: _spec, size: 48),
          ),
        ),
      );
      await tester.tapAt(const Offset(400, 400));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
