import "dart:async";

import "package:flutter/foundation.dart" show protected;
import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// iOS's local notifications, behind `agent_chat/reminders` and
/// `RemindersPlugin.swift`.
///
/// Nothing wakes the process: what the system delivers with the app closed is
/// the notification [schedule] composed (hence its label and chat id), and the
/// turn runs at the clock kinds' launch catch-up. So [schedules] is true, and
/// there is no fire half — [fired] is empty and [takeFired] answers nothing.
/// [MacosReminderAlarms] shares all of this but the arm.
class IosReminderAlarms implements ReminderAlarms {
  IosReminderAlarms() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/reminders");

  final _opens = StreamController<String>.broadcast();

  @override
  bool get available => true;

  @override
  bool get schedules => true;

  @override
  Stream<String> get openChat => _opens.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case "open":
        // Nudge only: the id itself lives in the plugin's stash, where a tap
        // that launched the process left it for this drain.
        final chatId = call.arguments as String?;
        if (chatId != null) _opens.add(chatId);
    }
  }

  // No exact-alarm permission exists to be denied: notification authorization
  // is the one gate.
  @override
  Future<bool> exactAllowed() async => true;

  @override
  Future<void> requestExact() async {}

  @override
  Future<bool> notificationsAllowed() async =>
      await _channel.invokeMethod<bool>("notificationsAllowed") ?? false;

  @override
  Future<void> requestNotifications() =>
      _channel.invokeMethod("requestNotifications");

  @override
  Future<void> schedule(int requestCode, DateTime at,
          {String? calendar, String? label, String? chatId}) =>
      run(
        "schedule",
        {
          "code": requestCode,
          "at": at.millisecondsSinceEpoch,
          "calendar": ?calendar,
          "label": ?label,
          "chatId": ?chatId,
        },
        "schedule $requestCode",
      );

  @override
  Future<void> cancel(int requestCode) =>
      run("cancel", {"code": requestCode}, "cancel $requestCode");

  @override
  Future<List<int>> staleCodes(Set<int> wanted) =>
      listStale({"wanted": wanted.toList()});

  @protected
  Future<List<int>> listStale(Map<Object, Object?> arguments) async {
    try {
      return await _channel.invokeListMethod<int>("staleCodes", arguments) ??
          const [];
    } catch (error) {
      logFailure("reminders", "scheduled listing not read; none pruned", error);
      return const [];
    }
  }

  // Foreground, or yes: the brief window after backgrounding is the one
  // place a claimed fire could be killed by the suspension.
  @override
  Future<bool> canHoldTurn() async =>
      await _channel.invokeMethod<bool>("canHoldTurn") ?? true;

  @override
  Future<void> doneFiring() async {}

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    // No channel to pick: the notification centre has no per-app groups.
    try {
      await _channel
          .invokeMethod(
            "notify",
            {"title": title, "body": body, "chatId": ?chatId},
          )
          .timeout(ReminderAlarms.notifyTimeout);
    } catch (error) {
      logFailure("reminders", "notification not posted", error);
    }
  }

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Stream<void> get fired => const Stream<void>.empty();

  @override
  Future<String?> takeOpenChat() =>
      _channel.invokeMethod<String>("takeOpenChat");

  /// Never throws: the clock kind's diff awaits [schedule] and [cancel] before
  /// its watch's `started` completes, and the manager's reload holds on that.
  /// A refusal is a line; the trigger then fires as catch-up at next launch.
  @protected
  Future<void> run(String method, Map<Object, Object?> arguments,
      String what) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (error) {
      logFailure("reminders", "alarm not updated: $what", error);
    }
  }
}
