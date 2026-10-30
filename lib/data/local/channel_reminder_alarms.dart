import "dart:async";

import "package:flutter/foundation.dart" show mustCallSuper, protected;
import "package:flutter/services.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// What every port behind `agent_chat/reminders` shares: the tap route, the
/// notification permission, and calls that never throw.
///
/// A tapped notification is held-pending like everything else that can start
/// the process: the id waits on the platform side until [takeOpenChat] asks,
/// and the "open" invoke is only a nudge for an isolate that was already up.
abstract class ChannelReminderAlarms implements ReminderAlarms {
  ChannelReminderAlarms() {
    platform.setMethodCallHandler(onCall);
  }

  static const _channel = MethodChannel("agent_chat/reminders");

  @protected
  MethodChannel get platform => _channel;

  final _opens = StreamController<String>.broadcast();

  @override
  bool get available => true;

  @override
  bool get schedules => true;

  @override
  Stream<String> get openChat => _opens.stream;

  @protected
  @mustCallSuper
  Future<dynamic> onCall(MethodCall call) async {
    if (call.method != "open") return;
    final chatId = call.arguments as String?;
    if (chatId != null) _opens.add(chatId);
  }

  @override
  Future<bool> notificationsAllowed() async =>
      await platform.invokeMethod<bool>("notificationsAllowed") ?? false;

  @override
  Future<void> requestNotifications() =>
      platform.invokeMethod("requestNotifications");

  // No answer means yes: a platform that cannot say is not a reason to leave a
  // reminder unrun, and running it merely killable is where every other
  // platform already is.
  @override
  Future<bool> canHoldTurn() async =>
      await platform.invokeMethod<bool>("canHoldTurn") ?? true;

  // Apple's notification centre has no per-app groups and ignores [channel].
  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    try {
      await platform
          .invokeMethod("notify", {
            "title": title,
            "body": body,
            "chatId": ?chatId,
            "channel": channel,
          })
          .timeout(ReminderAlarms.notifyTimeout);
    } catch (error) {
      logFailure("reminders", "notification not posted", error);
    }
  }

  @override
  Future<String?> takeOpenChat() =>
      platform.invokeMethod<String>("takeOpenChat");

  /// Never throws: the clock kind's diff awaits [schedule] and [cancel] before
  /// its watch's `started` completes, and the manager's reload holds on that.
  /// A refusal is a line; the trigger then fires as catch-up at next launch.
  @protected
  Future<void> run(
    String method,
    Map<Object, Object?> arguments,
    String what,
  ) async {
    try {
      await platform.invokeMethod(method, arguments);
    } catch (error) {
      logFailure("reminders", "alarm not updated: $what", error);
    }
  }
}
