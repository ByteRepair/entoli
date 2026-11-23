import "dart:typed_data";

import "bot_avatar/spec.dart";

/// What an agent looks like where it is shown: a photo the user picked, or a
/// Bot Avatar drawn live. An agent with neither has no face, and the person
/// mark stands in for one.
sealed class AgentFace {
  const AgentFace();

  /// The Bot Avatar it wears, where it is one.
  BotAvatarSpec? get bot => null;
}

/// A picked image — the `<name>.png` beside the agent's `.md`.
final class AgentPhoto extends AgentFace {
  const AgentPhoto(this.bytes);
  final Uint8List bytes;
}

/// A Bot Avatar — the `<name>.avatar.json` beside the agent's `.md`.
final class AgentBot extends AgentFace {
  const AgentBot(this.spec);
  final BotAvatarSpec spec;

  @override
  BotAvatarSpec get bot => spec;
}
