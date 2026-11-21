import "package:flutter_riverpod/flutter_riverpod.dart";

import "spec.dart" show SettingsPageId;

/// What the UI opens as a page of its own rather than as a setting: a
/// paired device's page, every Bot Avatar. The UI at the window's root
/// binds them; unbound, a setting that needs one does not offer it.
class SettingsHandOff {
  /// The page that adds an on-device model by its link.
  Future<void> Function()? addModelByLink;

  /// A paired device's own page: its name to change, and the fingerprints a
  /// pair exists to compare.
  Future<void> Function(String deviceId)? pairedDevice;

  /// Every Bot Avatar, to look through, import and delete.
  Future<void> Function()? browseBotAvatars;

  /// The settings, at [page] where it names one: what an app page's row
  /// sends the user to.
  Future<void> Function(SettingsPageId? page)? openSettings;

  /// Unbinds every hook, for the UI going away.
  void clear() {
    addModelByLink = null;
    pairedDevice = null;
    browseBotAvatars = null;
    openSettings = null;
  }
}

final settingsHandOffProvider = Provider<SettingsHandOff>(
  (ref) => SettingsHandOff(),
);
