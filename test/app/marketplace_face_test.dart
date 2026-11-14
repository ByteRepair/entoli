import "package:flutter/services.dart" show rootBundle;
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/marketplace/face.dart";
import "package:agent_chat/data/bot_avatar_library.dart";
import "package:agent_chat/domain/bot_avatar/spec.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("a key always wears the same face, coloured from the key", () async {
    final presets = await loadBotAvatarPresets(rootBundle);
    final a = marketplaceFace("google/gcs", presets)!;
    final again = marketplaceFace("google/gcs", presets)!;
    expect(again.definition.id, a.definition.id);
    expect(a.colour, BotPalette.ownColour("google/gcs"));
    // Not one face for everything.
    final ids = {
      for (final key in ["a", "b", "c", "d", "e", "f", "g", "h"])
        marketplaceFace(key, presets)!.definition.id,
    };
    expect(ids.length, greaterThan(1));
  });

  test("no presets, no face", () {
    expect(marketplaceFace("google/gcs", const []), isNull);
  });
}
