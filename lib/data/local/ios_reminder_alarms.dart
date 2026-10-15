import "dart:async";

import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// iOS's local notifications, behind `agent_chat/reminders` and
/// `RemindersPlugin.swift`.
///
/// The system clock is a notifications clock: nothing wakes the process, so
/// what the system delivers with the app closed is the due notification the
/// arm composed — [schedule] carries the label and the chat id for exactly
/// that — and the turn itself runs at the clock kinds' launch catch-up, the
/// path every missed fire already lands in. So [schedules] is true for it:
/// the clock does deliver the moment dead, worded "Ran late" on the runs that
/// waited. There is no fire half — [fired] is empty and [takeFired] answers
/// nothing — the macOS shape.
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

  // No exact-alarm permission exists to be denied, and the editor's "approx."
  // and the settings row ask this before showing anything: notification
  // authorization is the one gate, and [notificationsAllowed] is where it is
  // asked.
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
      _run(
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
      _run("cancel", {"code": requestCode}, "cancel $requestCode");

  @override
  Future<List<int>> staleCodes(Set<int> wanted) async {
    try {
      return await _channel.invokeListMethod<int>(
            "staleCodes",
            {"wanted": wanted.toList()},
          ) ??
          const [];
    } catch (error) {
      logFailure("reminders", "notification listing not read; none pruned",
          error);
      return const [];
    }
  }

  // Foreground, or yes: the brief window after backgrounding is the one
  // place a claimed fire could be killed by the suspension, and there the
  // defer dance re-arms it a notification rather than half-running it.
  @override
  Future<bool> canHoldTurn() async =>
      await _channel.invokeMethod<bool>("canHoldTurn") ?? true;

  // Nothing was held: no receiver intercepted a wake, the OS posted its
  // notification all the same.
  @override
  Future<void> doneFiring() async {}

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    // No channel to pick: the notification centre has no per-app groups the
    // way Android's channels are.
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

  /// The clock kind's diff awaits [schedule] and [cancel] before its watch's
  /// `started` completes, and the manager's reload holds on that — a thrown
  /// error here would complete nothing and hold every reload after it. A
  /// refused authorization is a line, not a stall; the trigger then fires as
  /// catch-up at the next launch, which is where every missed fire already
  /// lands.
  Future<void> _run(String method, Map<Object, Object?> arguments,
      String what) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (error) {
      logFailure("reminders", "notification not armed: $what", error);
    }
  }
}