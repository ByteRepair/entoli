import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/apple_fm.dart";

/// The Swift half behind a mock `agent_chat/apple_fm`: what Dart asks for,
/// and the door Swift's `send` knocks on. The real channel has no
/// implementation on a test host. The channel under the mock is the export
/// [appleChannel] itself, so a name drift on the port is a compile error here
/// rather than a hung test.
class AppleChannelMock {
  /// Every call Dart made, in order.
  final asked = <MethodCall>[];

  /// What a call is answered with; throwing is how Swift refuses one.
  Object? Function(MethodCall call) answer = (_) => null;

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(appleChannel, (call) async {
        asked.add(call);
        return answer(call);
      });

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appleChannel, null);
    asked.clear();
    answer = (_) => null;
  }

  /// A frame from Swift, delivered through the bridge.
  Future<void> incoming(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          appleChannel.name,
          appleChannel.codec.encodeMethodCall(MethodCall(method, arguments)),
          (_) {},
        );
    // The delivery's chain is microtasks through the broadcast; one zero
    // timer is the flush.
    await breathe();
  }

  /// One breathing round before a request has reached the mock at all: an
  /// async* generator starts on the next microtask, not eagerly.
  Future<void> breathe() => Future<void>.delayed(Duration.zero);

  /// Breathes until Dart has called [method], for a request that sits behind
  /// other channel round trips.
  Future<void> until(String method) async {
    for (
      var i = 0;
      i < 20 && !asked.any((call) => call.method == method);
      i++
    ) {
      await breathe();
    }
  }

  /// The one call to [method], as its arguments.
  Map<Object?, Object?> outgoing(String method) => asked
      .where((call) => call.method == method)
      .map((call) => call.arguments as Map<Object?, Object?>)
      .single;
}
