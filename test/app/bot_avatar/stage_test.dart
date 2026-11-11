import "package:agent_chat/app/bot_avatar/stage.dart";
import "package:agent_chat/domain/bot_avatar/definition.dart";
import "package:flutter_test/flutter_test.dart";

final _box =
    (BotAvatarDefinition.validate({
              "version": 1,
              "id": "box",
              "name": "Box",
              "body": {"path": "M20 20 H80 V80 H20 Z"},
              "eyes": {"x": 50, "y": 46, "spacing": 15, "scale": 1},
            })
            as BotAvatarValid)
        .definition;

/// The kind and place of each shape in an encoded frame.
List<(int, double)> _shapes(List<double> frame) => [
  for (var i = 0; i < frame[7]; i++)
    (frame[8 + i * 13].toInt(), frame[9 + i * 13]),
];

void main() {
  test("every slice a frame names is one the geometry sent", () {
    final stage = BotStage();
    final key = stage.keyOf(_box);
    final count = stage.geometry(key)!.first;
    final frame = stage.frame("a", key, now: const Duration(seconds: 1))!;
    final shapes = _shapes(frame);
    expect(shapes.where((s) => s.$1 == 0), isNotEmpty);
    for (final (kind, at) in shapes) {
      if (kind == 0) expect(at, inInclusiveRange(0, count - 1));
    }
    // Two eyes, drawn as open pills at rest.
    expect(shapes.where((s) => s.$1 == 1), hasLength(2));
  });

  test("a tap plays its reaction on a still, and ends", () {
    final stage = BotStage();
    final key = stage.keyOf(_box);
    var frame = stage.frame("a", key, now: Duration.zero, live: false)!;
    expect(frame.first, 0);
    stage.tap("a", Duration.zero);
    frame = stage.frame(
      "a",
      key,
      now: const Duration(seconds: 1),
      live: false,
    )!;
    expect(frame.first, 1);
    // Happy: the eyes are arcs.
    expect(_shapes(frame).where((s) => s.$1 == 2), hasLength(2));
    frame = stage.frame(
      "a",
      key,
      now: const Duration(seconds: 6),
      live: false,
    )!;
    expect(frame.first, 0);
  });

  test("a key never handed out has nothing to draw", () {
    final stage = BotStage();
    expect(stage.geometry("nobody#0"), isNull);
    expect(stage.frame("a", "nobody#0", now: Duration.zero), isNull);
  });
}
