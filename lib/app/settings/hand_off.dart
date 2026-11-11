import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/bot_avatar/spec.dart";
import "../../domain/llm_provider.dart";

/// What a frontend draws with its own page rather than as a setting: the Bot
/// Avatar editor, a program's sign-in, a paired device's page. The frontend
/// at the window's root binds them; unbound, a setting that needs one does
/// not offer it.
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

  /// Every Bot Avatar, to look through, import and delete.
  Future<void> Function()? browseBotAvatars;

  /// Unbinds every hook, for a frontend going away.
  void clear() {
    editBotAvatar = null;
    signIn = null;
    addModelByLink = null;
    pairedDevice = null;
    scanCode = null;
    browseBotAvatars = null;
  }
}

final settingsHandOffProvider = Provider<SettingsHandOff>(
  (ref) => SettingsHandOff(),
);
