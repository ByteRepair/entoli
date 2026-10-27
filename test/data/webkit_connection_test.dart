import "dart:convert";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/browser/cdp.dart";
import "package:agent_chat/data/browser/webkit_connection.dart";

// The Swift half behind a mock `agent_chat/browser`: what the tab's protocol
// calls become, and what the page's events come back as.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("agent_chat/browser");
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final asked = <MethodCall>[];
  late WebKitConnection cdp;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call);
      final args = call.arguments as Map;
      return switch (call.method) {
        "eval" when args["js"] == "throw" =>
          throw PlatformException(code: "exception", message: "Boom"),
        "eval" when (args["js"] as String).startsWith("[visualViewport") => [0, 100, 390, 844],
        "eval" => "value",
        "snapshot" => Uint8List.fromList([1, 2]),
        _ => null,
      };
    });
    cdp = WebKitConnection(channel);
  });

  tearDown(() async {
    await cdp.close();
    messenger.setMockMethodCallHandler(channel, null);
    asked.clear();
  });

  test("a script runs in the page script's world only where it names it", () async {
    final world = (await cdp.send("Page.createIsolatedWorld",
        sessionId: "c"))["executionContextId"];
    final ran = await cdp.send("Runtime.evaluate",
        params: {"expression": "1", "contextId": world}, sessionId: "c");
    await cdp.send("Runtime.evaluate", params: {"expression": "2"}, sessionId: "c");
    expect((ran["result"] as Map)["value"], "value");
    expect([for (final c in asked) (c.arguments as Map)["isolated"]], [true, false]);
    expect((asked.first.arguments as Map)["chat"], "c");
  });

  test("a thrown script is the protocol's exception, not a failed call", () async {
    final ran = await cdp.send("Runtime.evaluate",
        params: {"expression": "throw"}, sessionId: "c");
    expect((ran["exceptionDetails"] as Map)["text"], "Boom");
  });

  test("a screenshot's clip is moved from the document into the viewport", () async {
    final shot = await cdp.send("Page.captureScreenshot",
        params: {
          "clip": {"x": 10, "y": 150, "width": 50, "height": 20, "scale": 1 / 3},
        },
        sessionId: "c");
    expect(base64Decode(shot["data"] as String), [1, 2]);
    final snap = asked.last.arguments as Map;
    expect([snap["x"], snap["y"], snap["width"], snap["height"]], [10, 50, 50, 20]);
  });

  test("the page's events come back as the protocol's", () async {
    final seen = cdp.events.take(2).toList();
    for (final event in [
      {"type": "navigated", "chat": "c", "url": "https://example.com/"},
      {"type": "closed", "chat": "c"},
    ]) {
      await messenger.handlePlatformMessage(channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall("event", event)),
          (_) {});
    }
    final [navigated, closed] = await seen;
    expect(navigated.method, "Page.frameNavigated");
    expect(navigated.sessionId, "c");
    expect((navigated.params["frame"] as Map)["url"], "https://example.com/");
    expect(closed.method, "Target.targetDestroyed");
    expect(closed.sessionId, isNull);
  });

  test("what iOS has no answer to says so", () {
    expect(cdp.send("DOM.setFileInputFiles", sessionId: "c"),
        throwsA(isA<CdpException>()));
  });
}
