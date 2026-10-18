import "dart:async";

import "package:flutter/services.dart";

import "channel_reminder_alarms.dart";

/// Android's AlarmManager, behind `agent_chat/reminders` and
/// `RemindersChannel.kt`.
///
/// The held-pending split again, and both halves are needed for the same
/// reason the assistant gesture's are: the alarm may be what starts the
/// process, so a fire waits in Kotlin until [takeFired] asks, and [fired] is
/// only a nudge for an isolate that was already up.
class AndroidReminderAlarms extends ChannelReminderAlarms {
  final _nudges = StreamController<void>.broadcast();

  @override
  Stream<void> get fired => _nudges.stream;

  @override
  Future<dynamic> onCall(MethodCall call) async {
    if (call.method == "fired") _nudges.add(null);
    await super.onCall(call);
  }

  @override
  Future<bool> exactAllowed() async =>
      await platform.invokeMethod<bool>("exactAllowed") ?? false;

  @override
  Future<void> requestExact() => platform.invokeMethod("requestExact");

  @override
  Future<void> schedule(int requestCode, DateTime at,
          {String? calendar, String? label, String? chatId}) =>
      run("schedule", {"code": requestCode, "at": at.millisecondsSinceEpoch},
          "schedule $requestCode");

  @override
  Future<void> cancel(int requestCode) =>
      run("cancel", {"code": requestCode}, "cancel $requestCode");

  // Nothing Dart knows is held on this side: the boot receiver's re-arms live
  // in Kotlin, and a fire on a trigger since removed answers nothing to
  // takeFired — the receiver maps its code through the list on disk. No stale
  // enumeration to offer, so no prune ever cancels anything here.
  @override
  Future<List<int>> staleCodes(Set<int> wanted) async => const [];

  @override
  Future<void> doneFiring() => run("doneFiring", {}, "doneFiring");

  @override
  Future<List<String>> takeFired() async =>
      await platform.invokeListMethod<String>("takeFired") ?? const [];
}
