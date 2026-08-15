import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/app_icon.dart";

/// Enables one `activity-alias` and disables the rest, over the app's own
/// channel, answered in `MainActivity.kt`.
class LauncherAliases implements LauncherIcons {
  const LauncherAliases();

  static const _channel = MethodChannel("agent_chat/app_icon");

  /// Written out rather than derived from [AppIcon.label]: these have to match
  /// `AndroidManifest.xml`, not the UI copy.
  static const _aliases = {
    AppIcon.prompt: "PromptIcon",
    AppIcon.cookie: "CookieIcon",
  };

  @override
  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> use(AppIcon icon) async {
    if (!available) return;
    // Swallowed: the setting is already saved, and it is what the app draws
    // from.
    try {
      await _channel.invokeMethod<void>("use", _aliases[icon]);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }
}
