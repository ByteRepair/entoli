import "dart:async";

import "package:dbus/dbus.dart";

import "../../core/log.dart";
import "../../domain/reminder_alarms.dart";

/// What a session-bus round trip may take before it is said to have failed:
/// the probe one shot at launch, a post one pass on the scheduler's fire path.
const _probeTimeout = Duration(seconds: 5);
const _notifyTimeout = Duration(seconds: 10);

/// What the notifications half of the session bus does, as far as the alarms
/// care: post one, and hear when one of its actions was taken. The port keeps
/// the rest of `org.freedesktop.Notifications` behind this seam, which is what
/// a test stands for.
abstract interface class NotificationsBus {
  /// Post a notification and answer its id — the one an action arrives
  /// against. [actions] is the wire list, pairs of (key, label); empty is a
  /// notification with nothing to click. [replacesId] beyond zero names a
  /// notification to swap out rather than add beside.
  Future<int> notify(String title, String body, List<String> actions,
      {int replacesId = 0});

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
  Future<int> notify(String title, String body, List<String> actions,
      {int replacesId = 0}) async {
    final response = await _object.callMethod(null, "Notify", [
      const DBusString("Entoli"),
      DBusUint32(replacesId),
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
  Stream<(int, String)> get actionInvoked => DBusRemoteObjectSignalStream(
        object: _object,
        interface: "org.freedesktop.Notifications",
        name: "ActionInvoked",
        // A signal in another shape is refused here — and lands as an
        // error on the stream, which the reader below catches.
        signature: DBusSignature("us"),
      ).map((signal) =>
          (signal.values[0].asUint32(), signal.values[1].asString()));
}

/// Connect to the session bus, answering [UnavailableReminderAlarms] where
/// there is not one — a headless session, a minimal window manager, the dev
/// toolbox. The probe is once, at launch: the same bargain the keyring store
/// makes, a daemon that appears later being next launch's business. Bounded,
/// like every startup await: a bus that accepts and never answers is a stall
/// otherwise.
Future<ReminderAlarms> connectLinuxReminderAlarms() async {
  final client = DBusClient.session();
  try {
    await client.getId().timeout(_probeTimeout);
    return LinuxReminderAlarms(bus: _DBusNotifications(client));
  } catch (error) {
    await client.close();
    logFailure("reminders", "no session bus; reminders cannot notify", error);
    return const UnavailableReminderAlarms();
  }
}

/// Linux's reminders: notifications over the session bus, with the tap routed
/// back as a chat id — the halves the Android channel splits into
/// [ReminderAlarms.takeOpenChat] and [ReminderAlarms.openChat], held and
/// pushed the same way.
///
/// Nothing here schedules: the app's own timer is the scheduler on this
/// platform, and one missed while the app is closed is caught up at the next
/// launch. The answers that Android asks of a platform are yeses here — no
/// Doze, no foreground service, no exact-alarm permission.
class LinuxReminderAlarms implements ReminderAlarms {
  LinuxReminderAlarms({required NotificationsBus bus}) : _bus = bus {
    // A signal a daemon sends in another shape, or a bus that dies, must not
    // become an unhandled zone error: the subscription lasts the process.
    bus.actionInvoked.listen(_onAction,
        onError: (Object error) =>
            logFailure("reminders", "action signal unreadable", error));
  }

  final NotificationsBus _bus;

  /// The chat id a posted notification was for, by its id. A tap takes the
  /// entry out; a repost for the same chat id replaces the notification and
  /// rewrites the entry, the map growing only while notifications go untapped.
  final _chats = <int, String>{};

  /// The last id each chat's notification was posted under, so a repost
  /// replaces it in the daemon's tray rather than piling up beside it.
  final _ids = <String, int>{};

  final _opens = StreamController<String>.broadcast();

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
    // The key, not the label: "Open" is the label this side supplies,
    // "default" is what the body's click arrives as.
    if (key != "default") return;
    final chatId = _chats.remove(id);
    if (chatId == null) return;
    _ids.remove(chatId);
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
    // per-channel switches to honour. The wire wants (key, label) pairs, the
    // label ours to supply: a lone key registers no action at all.
    final actions = [if (chatId != null) ...["default", "Open"]];
    try {
      final replacesId = chatId == null ? 0 : (_ids[chatId] ?? 0);
      final id = await _bus.notify(title, body, actions, replacesId: replacesId)
          // A bus that accepts and never answers would hold the scheduler's
          // fire path forever; said rather than waited for.
          .timeout(_notifyTimeout);
      if (chatId != null) {
        _chats[id] = chatId;
        _ids[chatId] = id;
      }
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
