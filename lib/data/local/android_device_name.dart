import "dart:async";

import "package:flutter/services.dart";

import "../../core/log.dart";

/// Android, where the sync device name's default is the name the user set in
/// system settings — read through `agent_chat/device` from `DeviceChannel.kt`'s
/// `Settings.Global device_name`. `Platform.localHostname` is "localhost" on
/// Android, which is what the default was before this.
///
/// One method-channel read, matching the shape of the other Android ports
/// (`AndroidAssistantLaunch`, `AndroidReminderAlarms`): the io platform file
/// answers `Platform.isAndroid ? this : ...` and this class owns the channel.
class AndroidDeviceName {
  static const _channel = MethodChannel("agent_chat/device");

  /// The system device name, or null where the channel refused. A failure is
  /// logged rather than dropped: the repo's rule is that anything caught and
  /// carried on from gets a line, and a pairing that silently fell back to the
  /// fingerprint would otherwise say nothing about why.
  static Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>("name");
    } catch (error) {
      logFailure("sync", "could not read the Android device name", error);
      return null;
    }
  }
}
