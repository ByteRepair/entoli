import "dart:async";

import "package:flutter/services.dart";
import "package:entoli_core/model/log.dart";

/// The phones, where `Platform.localHostname` is "localhost": the sync device
/// name's default is read through `agent_chat/device` instead — Android's
/// `Settings.Global device_name` (`DeviceChannel.kt`), iOS's
/// `UIDevice.current.name` (`AppDelegate.swift`).
class SystemDeviceName {
  static const _channel = MethodChannel("agent_chat/device");

  /// The system device name, or null where the channel refused. A failure is
  /// logged rather than dropped: the repo's rule is that anything caught and
  /// carried on from gets a line, and a pairing that silently fell back to the
  /// fingerprint would otherwise say nothing about why.
  static Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>("name");
    } catch (error) {
      logFailure("sync", "could not read the device name", error);
      return null;
    }
  }
}
