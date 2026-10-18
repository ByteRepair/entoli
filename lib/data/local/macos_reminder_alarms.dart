import "ios_reminder_alarms.dart";

/// macOS's launchd and its notification centre, behind `agent_chat/reminders`
/// and `RemindersPlugin.swift`.
///
/// One launchd job per request code under `~/Library/LaunchAgents/`: a
/// one-line `sh` that spawns this binary detached with a wake argument and
/// exits, so the app's own bootouts never SIGTERM a living one, and removes
/// itself when the binary is gone. The label carries the data directory
/// [store], so another copy pointed elsewhere never shares or prunes its jobs.
///
/// No fire half, as on iOS: launchd can only start a process, and what the
/// wake was for is served by the clock kinds' launch catch-up.
class MacosReminderAlarms extends IosReminderAlarms {
  MacosReminderAlarms(this.store);

  final String store;

  @override
  Future<void> schedule(int requestCode, DateTime at,
          {String? calendar, String? label, String? chatId}) =>
      run(
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
      run("cancel", {"code": requestCode, "store": store}, "cancel $requestCode");

  @override
  Future<List<int>> staleCodes(Set<int> wanted) =>
      listStale({"wanted": wanted.toList(), "store": store});

  // A desktop process nobody is looking at is left alone, as on Linux.
  @override
  Future<bool> canHoldTurn() async => true;

  /// The wake session's work has drained; the Swift side quits a launch
  /// nobody came to look at. May never return.
  @override
  Future<void> doneFiring() => run("doneFiring", {}, "doneFiring");
}
