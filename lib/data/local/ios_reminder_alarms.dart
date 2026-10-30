import "package:flutter/foundation.dart" show protected;

import "../../core/log.dart";
import "channel_reminder_alarms.dart";

/// iOS's local notifications, behind `agent_chat/reminders` and
/// `RemindersPlugin.swift`.
///
/// Nothing wakes the process: what the system delivers with the app closed is
/// the notification [schedule] composed (hence its label and chat id), and the
/// turn runs at the clock kinds' launch catch-up. So [schedules] is true, and
/// there is no fire half — [fired] is empty and [takeFired] answers nothing.
/// [MacosReminderAlarms] shares all of this but the arm.
class IosReminderAlarms extends ChannelReminderAlarms {
  // No exact-alarm permission exists to be denied: notification authorization
  // is the one gate.
  @override
  Future<bool> exactAllowed() async => true;

  @override
  Future<void> requestExact() async {}

  @override
  Future<void> schedule(
    int requestCode,
    DateTime at, {
    String? calendar,
    String? label,
    String? chatId,
  }) => run("schedule", {
    "code": requestCode,
    "at": at.millisecondsSinceEpoch,
    "calendar": ?calendar,
    "label": ?label,
    "chatId": ?chatId,
  }, "schedule $requestCode");

  @override
  Future<void> cancel(int requestCode) =>
      run("cancel", {"code": requestCode}, "cancel $requestCode");

  @override
  Future<List<int>> staleCodes(Set<int> wanted) =>
      listStale({"wanted": wanted.toList()});

  @protected
  Future<List<int>> listStale(Map<Object, Object?> arguments) async {
    try {
      return await platform.invokeListMethod<int>("staleCodes", arguments) ??
          const [];
    } catch (error) {
      logFailure("reminders", "scheduled listing not read; none pruned", error);
      return const [];
    }
  }

  @override
  Future<void> doneFiring() async {}

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Stream<void> get fired => const Stream<void>.empty();
}
