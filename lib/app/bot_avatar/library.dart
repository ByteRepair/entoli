import "../../domain/bot_avatar/definition.dart";
import "../../domain/bot_avatar/spec.dart";

/// One shape the avatar editor offers, and where it came from.
class BotAvatarEntry {
  const BotAvatarEntry(this.definition, this.ownColour, this.source);

  final BotAvatarDefinition definition;

  /// The colour it shows until one is picked for it, and what Reset
  /// returns it to.
  final int ownColour;

  final BotAvatarSource source;
}

enum BotAvatarSource {
  /// Shipped with the app.
  preset,

  /// Pasted in on the Import tab; removable.
  imported,

  /// What the agent wore when the editor opened, where that is neither —
  /// an import since deleted, say.
  current,
}

/// What the editor offers: the presets, then the user's imports in their
/// own colours, with what the agent wears now first where it is neither.
List<BotAvatarEntry> botAvatarEntries(
  List<BotAvatarSpec> presets,
  List<BotAvatarDefinition> imported, {
  BotAvatarSpec? initial,
}) {
  final entries = [
    for (final p in presets)
      BotAvatarEntry(p.definition, p.colour, BotAvatarSource.preset),
    for (final d in imported)
      BotAvatarEntry(d, BotPalette.ownColour(d.id), BotAvatarSource.imported),
  ];
  if (initial != null &&
      !entries.any((e) => e.definition == initial.definition)) {
    entries.insert(
      0,
      BotAvatarEntry(
        initial.definition,
        initial.colour,
        BotAvatarSource.current,
      ),
    );
  }
  return entries;
}
