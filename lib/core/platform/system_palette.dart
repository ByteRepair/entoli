import "package:flutter/services.dart";

import "../log.dart";
import "form_factor.dart";

/// The colour the system is themed to, as ARGB, or null where it has none —
/// every platform but Android, and an Android older than 12. Read once at
/// startup, the way the ABI and the version are, so a wallpaper changed under
/// the app reaches it at the next launch.
Future<int?> systemAccent() async {
  if (!isAndroid) return null;
  try {
    return await const MethodChannel("agent_chat/palette").invokeMethod<int>("accent");
  } on PlatformException catch (e) {
    logFailure("palette", "system accent not read", e);
    return null;
  } on MissingPluginException catch (_) {
    return null;
  }
}
