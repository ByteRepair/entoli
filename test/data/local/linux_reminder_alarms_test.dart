import "dart:async";

import "package:agent_chat/data/local/linux_reminder_alarms.dart";
import "package:flutter_test/flutter_test.dart";

/// The notifications bus as a daemon a test controls: what was posted is
/// kept, and an action is delivered by hand the way a click would.
class FakeNotificationsBus implements NotificationsBus {
  var nextId = 1;

  /// The next [notify] fails where set, the way a session without a daemon
  /// would leave it.
  Object? failWith;

  final posted = <({String title, String body, List<String> actions, int replacesId})>[];
  final _actions = StreamController<(int, String)>.broadcast();

  /// The id the last [notify] was answered with, or 0 where none was.
  int get lastId => nextId - 1;

  @override
  Future<int> notify(String title, String body, List<String> actions,
      {int replacesId = 0}) async {
    final failure = failWith;
    if (failure != null) throw failure;
    posted.add((
      title: title,
      body: body,
      actions: actions,
      replacesId: replacesId,
    ));
    return nextId++;
  }

  @override
  Stream<(int, String)> get actionInvoked => _actions.stream;

  /// The user clicked a notification.
  void invoke(int id, String key) => _actions.add((id, key));
}

void main() {
  late FakeNotificationsBus bus;
  late LinuxReminderAlarms alarms;

  setUp(() {
    bus = FakeNotificationsBus();
    alarms = LinuxReminderAlarms(bus: bus);
  });

  test("available, and not scheduled against the system clock", () {
    expect(alarms.available, isTrue);
    expect(alarms.schedules, isFalse);
  });

  test("posting a reminder's completion carries its chat id as the tap", () async {
    await alarms.notify(title: "Morning sweep", body: "Finished.", chatId: "c1");

    expect(bus.posted.single.title, "Morning sweep");
    expect(bus.posted.single.body, "Finished.");
    // A pair of (key, label), the spec's shape — a lone key registers no
    // action, and the body's click arrives as "default".
    expect(bus.posted.single.actions, ["default", "Open"]);
    expect(bus.posted.single.replacesId, 0);
  });

  test("a notification with nothing to open offers no action", () async {
    await alarms.notify(title: "Entoli", body: "The turn failed.");

    expect(bus.posted.single.actions, isEmpty);
  });

  test("a tap arrives through both halves the port splits into", () async {
    await alarms.notify(title: "Morning sweep", body: "Finished.", chatId: "c1");

    final pushed = <String>[];
    final sub = alarms.openChat.listen(pushed.add);
    bus.invoke(bus.lastId, "default");
    await Future<void>.delayed(Duration.zero);

    // The push, for a wrapper already listening, and the drain, for the
    // read made on the first frame — the held-pending split.
    expect(pushed, ["c1"]);
    expect(await alarms.takeOpenChat(), "c1");
    expect(await alarms.takeOpenChat(), isNull);
    await sub.cancel();
  });

  test("a tap on another notification's action is not an open", () async {
    await alarms.notify(title: "Morning sweep", body: "Finished.", chatId: "c1");

    final opens = <String>[];
    final sub = alarms.openChat.listen(opens.add);
    bus.invoke(bus.lastId, "dismiss");
    await Future<void>.delayed(Duration.zero);

    expect(opens, isEmpty);
    expect(await alarms.takeOpenChat(), isNull);
    await sub.cancel();
  });

  test("a tap against a notification that was never posted is dropped", () async {
    final opens = <String>[];
    final sub = alarms.openChat.listen(opens.add);
    bus.invoke(99, "default");
    await Future<void>.delayed(Duration.zero);

    expect(opens, isEmpty);
    expect(await alarms.takeOpenChat(), isNull);
    await sub.cancel();
  });

  test("a repost for the same chat replaces the notification in the tray",
      () async {
    await alarms.notify(title: "One", body: "", chatId: "c1");
    await alarms.notify(title: "Two", body: "", chatId: "c1");

    // The second post names the first's id, so the daemon swaps it out
    // rather than piling a second one beside it; the tap then names the
    // newest id.
    expect(bus.posted, hasLength(2));
    expect(bus.posted[1].replacesId, bus.posted[0].replacesId + 1);
    await alarms.notify(title: "Three", body: "", chatId: "c2");
    bus.invoke(bus.lastId, "default");
    await Future<void>.delayed(Duration.zero);

    expect(await alarms.takeOpenChat(), "c2");
  });

  test("a tap retires the id, so a later post starts a fresh notification",
      () async {
    await alarms.notify(title: "One", body: "", chatId: "c1");
    bus.invoke(bus.lastId, "default");
    await Future<void>.delayed(Duration.zero);
    await alarms.notify(title: "Two", body: "", chatId: "c1");

    expect(bus.posted[1].replacesId, 0);
  });

  test("a failed post is carried, not thrown", () async {
    final failing = FakeNotificationsBus()..failWith = StateError("no daemon");
    final alarms = LinuxReminderAlarms(bus: failing);

    await alarms.notify(title: "Morning sweep", body: "Finished.", chatId: "c1");

    expect(await alarms.takeOpenChat(), isNull);
  });

  test("the answers Android asks of a platform are yeses here", () async {
    expect(await alarms.exactAllowed(), isTrue);
    expect(await alarms.notificationsAllowed(), isTrue);
    expect(await alarms.canHoldTurn(), isTrue);
    expect(await alarms.takeFired(), isEmpty);

    // Nothing to ask, nothing to schedule, nothing to release: the calls
    // the scheduler makes on every reload must not throw.
    await alarms.requestExact();
    await alarms.requestNotifications();
    await alarms.schedule(1, DateTime(2026));
    await alarms.cancel(1);
    await alarms.doneFiring();
  });
}
