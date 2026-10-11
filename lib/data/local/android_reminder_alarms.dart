import "dart:async";

import "package:flutter/services.dart";

import "../../domain/reminder_alarms.dart";

/// Android's AlarmManager, behind `agent_chat/reminders` and
/// `RemindersChannel.kt`.
///
/// The held-pending split again, and both halves are needed for the same
/// reason the assistant gesture's are: the alarm may be what starts the
/// process, so a fire waits in Kotlin until [takeFired] asks, and [fired] is
/// only a nudge for an isolate that was already up. A tapped notification
/// splits the same way, carrying its chat id through [takeOpenChat].
class AndroidReminderAlarms implements ReminderAlarms {
  AndroidReminderAlarms() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/reminders");

  final _nudges = StreamController<void>.broadcast();
  final _opens = StreamController<String>.broadcast();

  @override
  bool get available => true;

  @override
  bool get schedules => true;

  @override
  Stream<void> get fired => _nudges.stream;

  @override
  Stream<String> get openChat => _opens.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case "fired":
        _nudges.add(null);
      case "open":
        final chatId = call.arguments as String?;
        if (chatId != null) _opens.add(chatId);
    }
  }

  @override
  Future<bool> exactAllowed() async =>
      await _channel.invokeMethod<bool>("exactAllowed") ?? false;

  @override
  Future<void> requestExact() => _channel.invokeMethod("requestExact");

  @override
  Future<bool> notificationsAllowed() async =>
      await _channel.invokeMethod<bool>("notificationsAllowed") ?? false;

  @override
  Future<void> requestNotifications() =>
      _channel.invokeMethod("requestNotifications");

  @override
  Future<void> schedule(int requestCode, DateTime at) => _channel
      .invokeMethod("schedule", {"code": requestCode, "at": at.millisecondsSinceEpoch});

  @override
  Future<void> cancel(int requestCode) =>
      _channel.invokeMethod("cancel", {"code": requestCode});

  // Nothing Dart knows is held on this side: the boot receiver's re-arms live
  // in Kotlin, and a fire it makes on a trigger since removed answers nothing
  // to takeFired — the manager's own gate reads the list. No stale enumeration
  // to offer, so no prune ever cancels anything here.
  @override
  Future<List<int>> staleCodes(Set<int> wanted) async => const [];

  // No answer means yes: a platform that cannot say is not a reason to leave a
  // reminder unrun, and running it merely killable is where every other
  // platform already is.
  @override
  Future<bool> canHoldTurn() async =>
      await _channel.invokeMethod<bool>("canHoldTurn") ?? true;

  @override
  Future<void> doneFiring() => _channel.invokeMethod("doneFiring");

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) =>
      _channel.invokeMethod("notify", {
        "title": title,
        "body": body,
        "chatId": ?chatId,
        "channel": channel,
      });

  @override
  Future<List<String>> takeFired() async =>
      await _channel.invokeListMethod<String>("takeFired") ?? const [];

  @override
  Future<String?> takeOpenChat() async =>
      await _channel.invokeMethod<String>("takeOpenChat");
}
