import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/system_palette.dart";

/// Asks `ThemeChannel.kt` for `system_accent1_500`, the tone Android derives
/// its own palette from. The app seeds a scheme with it rather than reading
/// the whole system palette out: Material generates the other roles from one
/// colour, which is what Android did to arrive at these in the first place.
class SystemAccent implements SystemPalette {
  const SystemAccent();

  static const _channel = MethodChannel("agent_chat/palette");

  @override
  Future<int?> accent() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<int>("accent");
    } on PlatformException catch (e) {
      debugPrint("System accent not read: $e");
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }
}
