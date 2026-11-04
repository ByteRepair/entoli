import "dart:convert";
import "dart:io";

import "package:agent_chat/domain/bot_avatar/definition.dart";
import "package:agent_chat/domain/bot_avatar/frame.dart";
import "package:agent_chat/domain/bot_avatar/import.dart";
import "package:agent_chat/domain/bot_avatar/path.dart";
import "package:agent_chat/domain/bot_avatar/pose.dart";
import "package:agent_chat/domain/bot_avatar/spec.dart";
import "package:agent_chat/domain/bot_avatar/volume.dart";
import "package:flutter_test/flutter_test.dart";

Map<String, Object?> _box({String path = "M20 20 H80 V80 H20 Z"}) => {
  "version": 1,
  "id": "box",
  "name": "Box",
  "body": {"path": path},
  "eyes": {"x": 50, "y": 46, "spacing": 15, "scale": 1},
};

BotAvatarDefinition _valid(Object? json) =>
    (BotAvatarDefinition.validate(json) as BotAvatarValid).definition;

void main() {
  group("path", () {
    test("relative and shorthand commands come back absolute", () {
      expect(
        serializePath(parsePath("m10 10 h20 v20 h-20 z")),
        "M10 10L30 10L30 30L10 30Z",
      );
    });

    test("anything outside the command set is refused", () {
      expect(() => parsePath("M0 0 <script>"), throwsA(isA<PathError>()));
      expect(() => parsePath("L0 0"), throwsA(isA<PathError>()));
    });
  });

  group("definition", () {
    test("the README's box is valid and normalised", () {
      final def = _valid(_box());
      expect(def.path, "M20 20L80 20L80 80L20 80Z");
      expect(def.toJson()["eyes"], {
        "x": 50,
        "y": 46,
        "spacing": 15,
        "scale": 1,
      });
    });

    test("unknown keys, small bodies and eyes outside are each said", () {
      final result =
          BotAvatarDefinition.validate({..._box(), "color": "#fff"})
              as BotAvatarInvalid;
      expect(result.errors.single, contains('unknown field "color"'));

      final small =
          BotAvatarDefinition.validate(_box(path: "M45 45 H55 V55 H45 Z"))
              as BotAvatarInvalid;
      expect(small.errors, contains(contains("too small")));
      expect(small.errors, contains(contains("eyes must sit inside")));
    });
  });

  group("presets", () {
    final specs =
        (jsonDecode(
                  File(
                    "assets/bot_avatars/open-bot-avatar/presets.json",
                  ).readAsStringSync(),
                )
                as List)
            .map(BotAvatarSpec.fromJson)
            .toList();

    test("every preset is a valid spec with its own colour", () {
      expect(specs, hasLength(22));
      expect(specs, everyElement(isNotNull));
      expect(specs.first!.definition.id, "controller");
      expect(specs.first!.colour, BotPalette.orange.rgb);
    });

    test("every preset draws a body and two eyes in every mood", () {
      for (final spec in specs) {
        final prepared = PreparedBotAvatar.of(spec!.definition);
        for (final mood in BotMood.values) {
          final frame = prepared.frame(time: 1.3, mood: mood);
          expect(
            frame.shapes.whereType<SliceShape>(),
            isNotEmpty,
            reason: spec.definition.id,
          );
          final eyes = frame.shapes.whereType<EyeShapeMark>().toList();
          expect(eyes, hasLength(2), reason: "${spec.definition.id} $mood");
          expect(eyes.every((e) => e.mark is ArcMark), mood == BotMood.happy);
        }
      }
    });

    test("the barbell turns about one axis and the mug's cup stands up", () {
      final byId = {for (final s in specs) s!.definition.id: s};
      final barbell = PreparedBotAvatar.of(byId["barbell"]!.definition);
      expect(
        barbell.volume.parts.map((p) => p.kind),
        everyElement(PartKind.revolveX),
      );
      final mug = PreparedBotAvatar.of(byId["mug"]!.definition);
      expect(mug.volume.parts, hasLength(2));
      expect(mug.volume.eyeScale, greaterThan(1.15));
    });
  });

  group("spec", () {
    test("round-trips through its JSON", () {
      final spec = BotAvatarSpec(definition: _valid(_box()), colour: 0x1fbf68);
      expect(BotAvatarSpec.decode(spec.encode()), spec);
      expect(spec.toJson()["color"], "#1fbf68");
    });

    test("an invalid definition is no spec", () {
      expect(
        BotAvatarSpec.fromJson({"definition": {}, "color": "#fff"}),
        isNull,
      );
      expect(BotAvatarSpec.decode("not json"), isNull);
    });
  });

  group("import", () {
    test("a fenced reply is read and said so", () {
      final result = BotAvatarImport.parse(
        "Here you go:\n```json\n${jsonEncode(_box())}\n```\nEnjoy",
      );
      expect(result, isA<BotAvatarImported>());
      expect((result as BotAvatarImported).definitions.single.id, "box");
      expect(result.notes, ["Used the JSON inside the code fence."]);
    });

    test("broken JSON gets hints, a broken definition its errors", () {
      final syntax =
          BotAvatarImport.parse('{"id": "x",}') as BotAvatarImportFailed;
      expect(syntax.hints, contains(contains("trailing commas")));
      final contract =
          BotAvatarImport.parse(jsonEncode({..._box(), "version": 2}))
              as BotAvatarImportFailed;
      expect(contract.errors, ["version must be 1"]);
    });
  });

  group("animator", () {
    test("a mood change eases in and then settles", () {
      final animator = BotAnimator();
      expect(animator.step(now: 0, mood: BotMood.idle).blend, isNull);
      final mid = animator.step(now: 100, mood: BotMood.happy);
      expect(mid.blend, isNotNull);
      final done = animator.step(now: 100 + moodMs + 1, mood: BotMood.happy);
      expect(done.blend, isNull);
    });
  });

  test("looking down tips the face down as clearly as looking up lifts it", () {
    Pose at(double y) =>
        computePose(seed: 1, time: 1.3, mood: BotMood.idle, gaze: Gaze(0, y));
    final ahead = at(0).pitch;
    expect(ahead - at(1).pitch, greaterThan(at(-1).pitch - ahead));
  });
}
