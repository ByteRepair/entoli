import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/android_reminder_alarms.dart";

// The shared channel half, through Android's port: a platform that refuses is
// a logged line, never a throw into the clock kind's diff.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("agent_chat/reminders");
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final asked = <MethodCall>[];

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    asked.clear();
  });

  Future<void> incoming(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  test("schedule, cancel, notify and doneFiring swallow a refusal", () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      throw PlatformException(code: "reminders");
    });
    final alarms = AndroidReminderAlarms();
    await alarms.schedule(7, DateTime.fromMillisecondsSinceEpoch(1000));
    await alarms.cancel(7);
    await alarms.notify(title: "t", body: "b", chatId: "c");
    await alarms.doneFiring();
    expect(asked.map((c) => c.method),
        ["schedule", "cancel", "notify", "doneFiring"]);
    expect(asked.first.arguments, {"code": 7, "at": 1000});
    expect(asked[2].arguments,
        {"title": "t", "body": "b", "chatId": "c", "channel": "reminders"});
  });

  test("fired and open nudges reach their streams", () async {
    final alarms = AndroidReminderAlarms();
    final fired = expectLater(alarms.fired, emits(null));
    final opened = expectLater(alarms.openChat, emits("chat-1"));
    await incoming("fired");
    await incoming("open", "chat-1");
    await fired;
    await opened;
  });
}
