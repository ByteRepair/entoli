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
/// each a one-line `sh` that checks its binary, names [store], spawns this
/// binary detached with a wake argument the Runner hides the whole app under
/// and exits — the shell is launchd's whole tracked instance, so the app's
/// own bootouts and cancels of the label never SIGTERM a living one — which
/// is how a trigger fires with the process dead, what [schedules] is true
/// worth. The job also removes itself when its binary is gone — an uninstall
/// being the one case no writer survives — so no entry ever outlives the app
/// that wrote it. The job's label carries the data directory
/// [store], so another copy of this flavour pointed elsewhere never shares
/// its jobs, and no prune of this store's ever sees them.
///
/// Notifications are UNUserNotificationCenter. A tapped one takes its chat id
/// to the plugin's stash and nudges — the held-pending split Android's
/// channel makes: the nudge reaches Dart when the handler is there and is
/// dropped when it is not, and [takeOpenChat] drains the stash whichever way
/// the nudge went, which is what makes a tap that launched the process work.
///
/// There is deliberately no fire half. launchd's only power is starting a
/// process, and a running app on this platform keeps its event loop — so
/// whatever the wake was for is served by the clock kinds' own launch
/// catch-up, and [fired] is empty, [takeFired] answering nothing. The
/// Android channel's held-pending fire list has no job to do here.
class MacosReminderAlarms implements ReminderAlarms {
  MacosReminderAlarms(this.store) {
    _channel.setMethodCallHandler(_onCall);
  }

  /// The data directory whose triggers the jobs serve — the label's
  /// namespacing half.
  final String store;

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
        final chatId = call.arguments as String?;
        // Nudge only: the id itself lives in the plugin's stash, where a
        // tap that launched the process left it for this drain.
        if (chatId != null) _opens.add(chatId);
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
  Future<void> schedule(int requestCode, DateTime at, {String? calendar}) =>
      _run(
        "schedule",
        {
          "code": requestCode,
          "at": at.millisecondsSinceEpoch,
          "store": store,
          "calendar": ?calendar,
        },
        "schedule $requestCode",
      );

  @override
  Future<void> cancel(int requestCode) =>
      _run("cancel", {"code": requestCode, "store": store}, "cancel $requestCode");

  @override
  Future<List<int>> staleCodes(Set<int> wanted) async {
    try {
      return await _channel.invokeListMethod<int>(
            "staleCodes",
            {"wanted": wanted.toList(), "store": store},
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
  Future<String?> takeOpenChat() =>
      _channel.invokeMethod<String>("takeOpenChat");

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