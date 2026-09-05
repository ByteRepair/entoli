import "dart:async";

import "package:dbus/dbus.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// What the notifications half of the session bus does, as far as the alarms
/// care: post one, and hear when one of its actions was taken. The port keeps
/// the rest of `org.freedesktop.Notifications` behind this seam, which is what
/// a test stands in for.
abstract interface class NotificationsBus {
  /// Post a notification and answer its id — the one an action arrives
  /// against. Empty [actions] is a notification with nothing to click.
  Future<int> notify(String title, String body, List<String> actions);

  /// (notification id, action key) pairs, in the order they were taken.
  Stream<(int, String)> get actionInvoked;
}

/// The real one, over `org.freedesktop.Notifications` on the session bus.
///
/// No portal: the portal's Notification interface exists for sandboxed apps,
/// and an AppImage owns its bus name already — the direct interface is the
/// same shape everywhere and its action support is older than the portal's.
class _DBusNotifications implements NotificationsBus {
  _DBusNotifications(this._client);

  final DBusClient _client;

  late final _object = DBusRemoteObject(
    _client,
    name: "org.freedesktop.Notifications",
    path: DBusObjectPath("/org/freedesktop/Notifications"),
  );

  @override
  Future<int> notify(String title, String body, List<String> actions) async {
    final response = await _object.callMethod(null, "Notify", [
      const DBusString("Entoli"),
      const DBusUint32(0),
      const DBusString(""),
      DBusString(title),
      DBusString(body),
      DBusArray.string(actions),
      DBusDict.stringVariant(const {}),
      const DBusInt32(-1),
    ]);
    return response.returnValues.first.asUint32();
  }

  @override
  Stream<(int, String)> get actionInvoked =>
      DBusRemoteObjectSignalStream(
        object: _object,
        interface: "org.freedesktop.Notifications",
        name: "ActionInvoked",
      ).map((signal) {
        // Read defensively: no signature is demanded of the signal, so a
        // server that sends something else fails here rather than the app.
        return (signal.values[0].asUint32(), signal.values[1].asString());
      });
}

/// Connect to the session bus, answering null where there is not one — a
/// headless session, a minimal window manager, the dev toolbox. The probe is
/// once, at launch: the same bargain the keyring store makes, a daemon that
/// appears later being next launch's business.
Future<ReminderAlarms> connectLinuxReminderAlarms() async {
  try {
    final client = DBusClient.session();
    await client.getId();
    return LinuxReminderAlarms(bus: _DBusNotifications(client));
  } catch (error) {
    logFailure("reminders", "no session bus; reminders cannot notify", error);
    return const UnavailableReminderAlarms();
  }
}

/// Linux's reminders, phase one: notifications over the session bus, with the
/// tap routed back as a chat id — the halves the Android channel splits into
/// [ReminderAlarms.takeOpenChat] and [ReminderAlarms.openChat], held and
/// pushed the same way.
///
/// Nothing here schedules: no clock to hand over yet, so every reminder still
/// rides the in-process timer alone, and one missed while the app is closed
/// is caught up at the next launch. The answers that Android asks of a
/// platform are yeses here — no Doze, no foreground service, no
/// exact-alarm permission.
class LinuxReminderAlarms implements ReminderAlarms {
  LinuxReminderAlarms({required NotificationsBus bus}) : _bus = bus {
    bus.actionInvoked.listen(_onAction);
  }

  final NotificationsBus _bus;

  /// The chat id a posted notification was for, by its id. A tap takes the
  /// entry out; what is never tapped is swept by the next post for the same
  /// reminder, the map being one entry per reminder at most in practice.
  final _chats = <int, String>{};

  final _opens = StreamController<String>.broadcast();

  /// The tap that is waiting to be taken, if any.
  String? _pendingOpen;

  @override
  bool get available => true;

  @override
  bool get schedules => false;

  @override
  Stream<void> get fired => const Stream<void>.empty();

  @override
  Stream<String> get openChat => _opens.stream;

  void _onAction((int, String) event) {
    final (id, key) = event;
    // The key, not the label: "Open" is what the server shows, "default" is
    // what the body's click arrives as.
    if (key != "default") return;
    final chatId = _chats.remove(id);
    if (chatId == null) return;
    _pendingOpen = chatId;
    // The invoke behind a nudge is all Android's channel is for a fire that
    // arrives while the app is up; this is the same nudge, for the same
    // reason — the wrapper's stream is the push and [takeOpenChat] is the
    // drain.
    _opens.add(chatId);
  }

  @override
  Future<bool> exactAllowed() async => true;

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
  Future<bool> canHoldTurn() async => true;

  @override
  Future<void> doneFiring() async {}

  @override
  Future<void> notify({
    required String title,
    required String body,
    String? chatId,
    String channel = ReminderAlarms.defaultChannel,
  }) async {
    // One action, the default: clicking the notification is opening the chat,
    // and a second button beside it would be a menu where nothing else has
    // one. No channel to pick — the desktop's notification daemon has no
    // per-channel switches to honour.
    final actions = [if (chatId != null) "default"];
    try {
      final id = await _bus.notify(title, body, actions);
      if (chatId != null) _chats[id] = chatId;
    } catch (error) {
      logFailure("reminders", "notification not posted", error);
    }
  }

  @override
  Future<List<String>> takeFired() async => const [];

  @override
  Future<String?> takeOpenChat() async {
    final chatId = _pendingOpen;
    _pendingOpen = null;
    return chatId;
  }
}