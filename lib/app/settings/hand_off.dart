import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/spec.dart";

/// What a frontend draws with its own page rather than as a setting: the Bot
/// Avatar editor, which is the Flutter app's whatever draws the settings.
/// The frontend that can show it binds it; unbound, a setting that needs it
/// does not offer it.
class SettingsHandOff {
  /// The avatar editor opened on [initial], answering what was made, or null
  /// where it was left.
  Future<BotAvatarSpec?> Function(BotAvatarSpec? initial)? editBotAvatar;
}

final settingsHandOffProvider = Provider<SettingsHandOff>(
  (ref) => SettingsHandOff(),
);
