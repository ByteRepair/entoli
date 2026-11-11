import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/spec.dart";
import "../../domain/llm_provider.dart";

/// What a frontend draws with its own page rather than as a setting: the Bot
/// Avatar editor, which is the Flutter app's whatever draws the settings.
/// The frontend that can show it binds it; unbound, a setting that needs it
/// does not offer it.
class SettingsHandOff {
  /// The avatar editor opened on [initial], answering what was made, or null
  /// where it was left.
  Future<BotAvatarSpec?> Function(BotAvatarSpec? initial)? editBotAvatar;

  /// A program's own sign-in run for [config], its page opened and its code
  /// pasted back; signing out first where [again].
  Future<void> Function(LlmProviderConfig config, {bool again})? signIn;

  /// The page that adds an on-device model by its link.
  Future<void> Function()? addModelByLink;

  /// A paired device's own page: its name to change, and the fingerprints a
  /// pair exists to compare.
  Future<void> Function(String deviceId)? pairedDevice;

  /// The camera, pointed at a pairing code another screen shows, answering
  /// the code read.
  Future<String?> Function()? scanCode;
}

final settingsHandOffProvider = Provider<SettingsHandOff>(
  (ref) => SettingsHandOff(),
);
