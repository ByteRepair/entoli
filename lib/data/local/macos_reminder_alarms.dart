import "dart:async";

import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// How long a notification post may take before it is said to have failed —
/// the fire path's only unbounded round trip otherwise, the same bargain
/// Linux's session-bus post makes.
const _notifyTimeout = Duration(seconds: 10);

/// macOS's launchd and its notification centre, behind `agent_chat/reminders`
/// and `RemindersPlugin.swift`.
///
/// Scheduling is one launchd job per request code under `~/Library/LaunchAgents/`,
/// each running `open -gj` with a wake argument the Runner hides its window
/// under — which is how a trigger fires with the process dead, what
/// [schedules] is true worth. Notifications are UNUserNotificationCenter; a
/// tapped one takes its chat id, held for [takeOpenChat] and nudged onto
/// [openChat] — the held-pending split the Android channel and Linux's bus
/// make of the same thing.
///
/// There is deliberately no fire half. launchd's only power is starting a
/// process, and a running app on this platform keeps its event loop — so
/// whatever the wake was for is served by the clock kinds' own launch
/// catch-up, and [fired] is empty, [takeFired] answering nothing. The
/// Android channel's held-pending fire list has no job to do here.
class MacosReminderAlarms implements ReminderAlarms {
  MacosReminderAlarms() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/reminders");

  final _opens = StreamController<String>.broadcast();

  String? _pendingOpen;

  @override
  bool get available => true;

  @override
  bool get schedules => true;

  @override
  Stream<String> get openChat => _opens.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case "open":
        final chatId = call.arguments as String?;
        if (chatId != null) {
          _pendingOpen = chatId;
          _opens.add(chatId);
        }
    }
  }

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
  Future<void> schedule(int requestCode, DateTime at) => _run(
        "schedule",
        {"code": requestCode, "at": at.millisecondsSinceEpoch},
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
      logFailure("reminders", "launchd job listing not read; none pruned",
          error);
      return const [];
    }
  }

  // No answer means yes: a desktop process nobody is looking at is left
  // alone, the way Linux's is.
  @override
  Future<bool> canHoldTurn() async => true;

  /// The wake session's work has drained; the Swift side quits a launch
  /// nobody came to look at. May never return — the process is going — which
  /// is what a terminate is.
  @override
  Future<void> doneFiring() => _run("doneFiring", {}, "doneFiring");

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    // No channel to pick: the notification centre has no per-app groups the
    // way Android's channels are — Linux's daemon said the same of itself.
    try {
      await _channel
          .invokeMethod(
            "notify",
            {"title": title, "body": body, "chatId": ?chatId},
          )
          .timeout(_notifyTimeout);
    } catch (error) {
      logFailure("reminders", "notification not posted", error);
    }
  }

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Stream<void> get fired => const Stream<void>.empty();

  @override
  Future<String?> takeOpenChat() async {
    final chatId = _pendingOpen;
    _pendingOpen = null;
    return chatId;
  }

  /// The clock kind's diff awaits [schedule] and [cancel] before its watch's
  /// `started` completes, and the manager's reload holds on that — a thrown
  /// error here would complete nothing and hold every reload after it. A
  /// refused boot or a launchctl that failed is a line, not a stall; the
  /// trigger then fires as catch-up at the next launch, which is where every
  /// missed fire already lands.
  Future<void> _run(String method, Map<Object, Object?> arguments,
      String what) async {
    try {
      await _channel.invokeMethod(method, arguments);
    } catch (error) {
      logFailure("reminders", "launchd job not updated: $what", error);
    }
  }
}