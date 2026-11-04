// What an agent looks like when it is a Bot Avatar: the definition (the
// shape) and the colours it is painted in. The spec is what is stored beside
// an agent and what a preset is.
import "dart:convert";

import "definition.dart";

/// The body colours the reference picker offers, in its order.
abstract final class BotPalette {
  static const white = BotSwatch(0xf4f4f4, "White");
  static const brown = BotSwatch(0xa8693f, "Brown");
  static const red = BotSwatch(0xf2384b, "Red");
  static const orange = BotSwatch(0xff6a1a, "Orange");
  static const amber = BotSwatch(0xf8a01c, "Amber");
  static const green = BotSwatch(0x1fbf68, "Green");
  static const teal = BotSwatch(0x14b3a5, "Teal");
  static const blue = BotSwatch(0x1f7cf2, "Blue");
  static const purple = BotSwatch(0x8b5cf6, "Purple");
  static const pink = BotSwatch(0xec4899, "Pink");
  static const gray = BotSwatch(0x7a7a7a, "Gray");

  static const all = [
    white,
    brown,
    red,
    orange,
    amber,
    green,
    teal,
    blue,
    purple,
    pink,
    gray,
  ];

  /// The colour an avatar gets where nobody picked one.
  static const signature = orange;

  /// The colour of an avatar of the user's own that nobody has coloured: a
  /// bright palette colour picked from its id, so it is the same everywhere.
  static int ownColour(String id) {
    final bright = [
      for (final s in all)
        if (s != white && s != gray) s.rgb,
    ];
    var hash = 0;
    for (final c in id.runes) {
      hash = (hash * 31 + c) & 0xffffffff;
    }
    return bright[hash % bright.length];
  }

  /// The name of [rgb] where it is on the palette.
  static String? nameOf(int rgb) {
    for (final s in all) {
      if (s.rgb == rgb) return s.name;
    }
    return null;
  }
}

class BotSwatch {
  const BotSwatch(this.rgb, this.name);

  /// 0xRRGGBB.
  final int rgb;
  final String name;
}

/// `#rrggbb` (or `#rgb`) as 0xRRGGBB, or null where it is neither.
int? parseHexColour(Object? input) {
  if (input is! String) return null;
  final m = RegExp(
    r"^#([0-9a-f]{3}|[0-9a-f]{6})$",
    caseSensitive: false,
  ).firstMatch(input.trim());
  if (m == null) return null;
  var h = m[1]!;
  if (h.length == 3) h = h.split("").map((c) => "$c$c").join();
  return int.parse(h, radix: 16);
}

String hexColour(int rgb) =>
    "#${(rgb & 0xffffff).toRadixString(16).padLeft(6, "0")}";

/// A Bot Avatar as an agent wears it.
class BotAvatarSpec {
  const BotAvatarSpec({
    required this.definition,
    required this.colour,
    this.eyeColour,
  });

  final BotAvatarDefinition definition;

  /// The body colour, 0xRRGGBB.
  final int colour;

  /// The eye ink, 0xRRGGBB; null is the reference's near-black.
  final int? eyeColour;

  static const defaultEyeColour = 0x151515;

  int get ink => eyeColour ?? defaultEyeColour;

  BotAvatarSpec withColour(int colour) => BotAvatarSpec(
    definition: definition,
    colour: colour,
    eyeColour: eyeColour,
  );

  /// A spec from its JSON — `{"definition": …, "color": "#rrggbb"}` — or
  /// null where the definition fails the contract or the JSON is not one.
  /// A colour that does not parse is the signature colour, as the
  /// reference falls back.
  static BotAvatarSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final result = BotAvatarDefinition.validate(json["definition"]);
    if (result is! BotAvatarValid) return null;
    return BotAvatarSpec(
      definition: result.definition,
      colour: parseHexColour(json["color"]) ?? BotPalette.signature.rgb,
      eyeColour: parseHexColour(json["eyeColor"]),
    );
  }

  /// [source] as a spec, or null where it is not one.
  static BotAvatarSpec? decode(String source) {
    try {
      return fromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }

  Map<String, Object> toJson() => {
    "definition": definition.toJson(),
    "color": hexColour(colour),
    if (eyeColour != null) "eyeColor": hexColour(eyeColour!),
  };

  String encode() => const JsonEncoder.withIndent("  ").convert(toJson());

  @override
  bool operator ==(Object other) =>
      other is BotAvatarSpec &&
      other.definition == definition &&
      other.colour == colour &&
      other.eyeColour == eyeColour;

  @override
  int get hashCode => Object.hash(definition, colour, eyeColour);
}
