/// The system clock a reminder is set against: AlarmManager on Android,
/// nothing anywhere else yet. The scheduler drives this port; it never runs a
/// prompt itself — Kotlin only ever nudges, and Dart decides what is due.
///
/// Two routes in, the shape [AssistantLaunch] has for the assistant gesture:
/// an alarm can be what starts the process, in which case Kotlin noticed it
/// long before Dart was listening. So the fired ids wait in Kotlin until
/// [takeFired] drains them, and [fired] is only a nudge for an isolate that
/// was already up.
abstract interface class ReminderAlarms {
  bool get available;

  /// Whether exact alarms are permitted right now. False is common on
  /// Android 14+, where the permission is denied by default; the scheduler's
  /// answer is inexact alarms, which can fire minutes late under Doze.
  Future<bool> exactAllowed();

  /// Open the system settings where exact alarms are granted.
  Future<void> requestExact();

  /// Whether this app may post notifications at all (Android 13+).
  Future<bool> notificationsAllowed();

  /// Asked from the Reminders settings page, where there is an activity to
  /// ask through. A cold-started process has none — see "Staying alive off
  /// screen" in `android/CLAUDE.md` — which is why this is not called from a
  /// firing path.
  Future<void> requestNotifications();

  Future<void> schedule(int requestCode, DateTime at);

  Future<void> cancel(int requestCode);

  /// Post the completion notification. [chatId] rides on its content intent:
  /// tapping it comes back through [takeOpenChat].
  Future<void> notify({required String title, required String body, String? chatId});

  Future<List<String>> takeFired();

  Stream<void> get fired;

  /// The chat id of a completion notification that was tapped, if any — held
  /// like the fires are, since the tap may be what starts the process.
  Future<String?> takeOpenChat();

  /// A tap arriving while the app is already up.
  Stream<String> get openChat;
}

/// A platform with no scheduling: nothing is ever due by the system's say-so,
/// which is what leaves every reminder to the in-process timer alone.
class UnavailableReminderAlarms implements ReminderAlarms {
  const UnavailableReminderAlarms();

  @override
  bool get available => false;

  @override
  Future<bool> exactAllowed() async => false;

  @override
  Future<void> requestExact() async {}

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<void> requestNotifications() async {}

  @override
  Future<void> schedule(int requestCode, DateTime at) async {}

  @override
  Future<void> cancel(int requestCode) async {}

  @override
  Future<void> notify({required String title, required String body, String? chatId}) async {}

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Stream<void> get fired => const Stream<void>.empty();

  @override
  Future<String?> takeOpenChat() async => null;

  @override
  Stream<String> get openChat => const Stream<String>.empty();
}
