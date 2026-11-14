import "../../domain/bot_avatar/pose.dart" show hashString;
import "../../domain/bot_avatar/spec.dart";

/// A marketplace row's face, picked from [key] alone so it is the same on
/// every device: a preset by hash, coloured as an uncoloured avatar of the
/// user's own would be. Tied to the bundled presets' order.
BotAvatarSpec? marketplaceFace(String key, List<BotAvatarSpec> presets) {
  if (presets.isEmpty) return null;
  return BotAvatarSpec(
    definition: presets[hashString(key) % presets.length].definition,
    colour: BotPalette.ownColour(key),
  );
}
