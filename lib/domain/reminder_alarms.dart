/// The system clock a reminder is set against: AlarmManager on Android,
/// launchd's user launch agents on macOS, scheduled local notifications on
/// iOS. The scheduler drives this port; it never runs a prompt itself —
/// Kotlin only ever nudges, and Dart decides what is due.
///
/// Two routes in, the shape [AssistantLaunch] has for the assistant gesture:
/// an alarm can be what starts the process, in which case the platform
/// noticed it long before Dart was listening. So the fired ids wait in Kotlin
/// until [takeFired] drains them, and [fired] is only a nudge for an isolate
/// that was already up.
abstract interface class ReminderAlarms {
  /// The Android channels notifications post on. Kotlin spells its half of
  /// the ids itself — a method channel's strings are literals on both sides —
  /// but the Dart call sites name them here, so a rename or a third channel
  /// is one grep, not three spellings.
  static const defaultChannel = "reminders";
  static const turnFailureChannel = "turns";

  /// How long a notification post may take before it is said to have failed —
  /// the fire path's only unbounded round trip otherwise, one patience for
  /// every platform that posts through a system it does not size: a rename or
  /// a retune here is one grep, not three spellings.
  static const notifyTimeout = Duration(seconds: 10);

  bool get available;

  /// Whether the system clock fires a reminder with the process dead —
  /// AlarmManager on Android, launchd on macOS. Where it is false the
  /// reminders page says so rather than promising a fire the app's own timer
  /// cannot make: a desktop still notifies what a reminder did, but only one
  /// that fired while it was running.
  bool get schedules;

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
  /// screen" in `android/AGENTS.md` — which is why this is not called from a
  /// firing path.
  Future<void> requestNotifications();

  /// Arms the clock at [at]. A repeating schedule's arm names [calendar] —
  /// its repeat's name — and the platforms with a calendar form arm that
  /// instead of a count: launchd's calendar firings are wall-clock anchored
  /// and coalesce what a sleep swallows, where an interval arm can be missed
  /// outright and measures awake time. One shots and timers have no calendar
  /// shape and leave it null everywhere.
  ///
  /// [label] and [chatId] name the arm where the platform tells the user the
  /// moment without waking for it: iOS's notification is posted by the system
  /// exactly when due, process dead included, so its words and tap route are
  /// fixed at arm time. The wake platforms compose nothing until the turn
  /// runs and ignore both.
  Future<void> schedule(int requestCode, DateTime at,
      {String? calendar, String? label, String? chatId});

  Future<void> cancel(int requestCode);

  /// The codes this port still holds that [wanted] does not name — jobs armed
  /// by a launch whose knowledge is gone: a trigger deleted or disabled while
  /// the app was closed has left its job behind, and on the platform that
  /// keeps jobs as files (launchd) one of those would wake the app forever.
  /// The manager cancels each answer through the ordinary path, after the
  /// clock kinds have armed theirs; answering nothing is always legitimate,
  /// and is what a port with nothing to enumerate says.
  Future<List<int>> staleCodes(Set<int> wanted);

  /// Whether a turn started right now could be held open. Android refuses a
  /// backgrounded app the foreground service that holds the process, and a turn
  /// nothing holds is one the system kills halfway — so a fire this answers
  /// false to is handed back to the alarm rather than run. True where there is
  /// nothing to ask: a desktop process nobody is looking at is left alone.
  Future<bool> canHoldTurn();

  /// The fires the alarm woke the process for have been dealt with. Android's
  /// receiver takes a hold of its own, before Dart is listening, and this is
  /// what releases it — a wake that turned out to have nothing to run would
  /// otherwise hold the process open for good.
  Future<void> doneFiring();

  /// Post a notification. [chatId] rides on its content intent: tapping it
  /// comes back through [takeOpenChat]. [channel] picks the Android channel —
  /// [defaultChannel] is the reminder completions, the one this port was
  /// built for; a turn failure posts on [turnFailureChannel] so the user can
  /// quiet one half without the other.
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  });

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
  bool get schedules => false;

  @override
  Future<bool> exactAllowed() async => false;

  @override
  Future<void> requestExact() async {}

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<void> requestNotifications() async {}

  @override
  Future<void> schedule(int requestCode, DateTime at,
      {String? calendar, String? label, String? chatId}) async {}

  @override
  Future<void> cancel(int requestCode) async {}

  @override
  Future<List<int>> staleCodes(Set<int> wanted) async => const [];

  @override
  Future<bool> canHoldTurn() async => true;

  @override
  Future<void> doneFiring() async {}

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {}

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Stream<void> get fired => const Stream<void>.empty();

  @override
  Future<String?> takeOpenChat() async => null;

  @override
  Stream<String> get openChat => const Stream<String>.empty();
}
