import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/app_icon.dart";

/// Tells `MainActivity.kt` which launcher entry to show. The default icon
/// (prompt) is what `MainActivity` itself wears via the app-level
/// `android:icon`, so selecting it sends `"MainActivity"` — answered by
/// `resetIcon`, which re-enables the activity and drops the alias. Every other
/// icon is an `activity-alias` enabled in the manifest's place.
class LauncherAliases implements LauncherIcons {
  const LauncherAliases();

  static const _channel = MethodChannel("agent_chat/app_icon");

  /// Written out rather than derived from [AppIcon.label]: these have to match
  /// `AndroidManifest.xml` and `MainActivity.kt`, not the UI copy.
  static const _components = {
    AppIcon.prompt: "MainActivity",
    AppIcon.cookie: "CookieIcon",
  };

  @override
  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> use(AppIcon icon) async {
    if (!available) return;
    // Swallowed: the setting is already saved, and it is what the app draws
    // from. Logged because a launcher that silently refuses looks exactly like
    // a bug in the setting.
    try {
      await _channel.invokeMethod<void>("use", _components[icon]);
    } on PlatformException catch (e) {
      debugPrint("Launcher icon not changed: $e");
    } on MissingPluginException catch (_) {}
  }
}
