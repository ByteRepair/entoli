import "package:flutter/services.dart";

import "../../domain/remote_control.dart";

/// Seeing and driving the screen through the accessibility service. The service
/// is a system component the user enables in system settings; the channel
/// reaches it, which captures the screen and injects gestures and keys. A call
/// while the service is not connected fails with a clear error.
class AndroidRemoteControl extends RemoteControl {
  AndroidRemoteControl();

  static const _channel = MethodChannel("agent_chat/remote_control");

  @override
  bool get available => true;

  /// Open the system's accessibility settings, where the user enables the
  /// service. The app cannot enable it itself. Static: it reaches the channel
  /// and needs no instance.
  static Future<void> openSettings() async {
    await _channel.invokeMethod("openSettings");
  }

  @override
  Future<Uint8List> screenshot() async {
    final bytes = await _channel.invokeMethod<Uint8List>("screenshot");
    if (bytes == null) {
      throw StateError("The accessibility service returned no screenshot.");
    }
    return bytes;
  }

  @override
  Future<void> click(int x, int y, {required int button}) async {
    await _channel.invokeMethod("click", {"x": x, "y": y, "button": button});
  }

  @override
  Future<void> key(String text) async {
    await _channel.invokeMethod("key", {"text": text});
  }
}
