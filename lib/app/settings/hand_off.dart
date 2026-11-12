import "package:flutter_riverpod/flutter_riverpod.dart";

/// What a frontend draws with its own page rather than as a setting: a
/// paired device's page, every Bot Avatar. The frontend
/// at the window's root binds them; unbound, a setting that needs one does
/// not offer it.
class SettingsHandOff {
  /// The page that adds an on-device model by its link.
  Future<void> Function()? addModelByLink;

  /// A paired device's own page: its name to change, and the fingerprints a
  /// pair exists to compare.
  Future<void> Function(String deviceId)? pairedDevice;

  /// Whether [pairedDevice] opens over the settings, where a frontend has
  /// a page of its own for it, rather than over the conversation.
  bool pairedDeviceInSettings = false;

  /// The camera, pointed at a pairing code another screen shows, answering
  /// the code read.
  Future<String?> Function()? scanCode;

  /// Every Bot Avatar, to look through, import and delete.
  Future<void> Function()? browseBotAvatars;

  /// Unbinds every hook, for a frontend going away.
  void clear() {
    addModelByLink = null;
    pairedDevice = null;
    pairedDeviceInSettings = false;
    scanCode = null;
    browseBotAvatars = null;
  }
}

final settingsHandOffProvider = Provider<SettingsHandOff>(
  (ref) => SettingsHandOff(),
);
