import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

/// The Swift half behind a mock of one of the native channels —
/// `agent_chat/apple_fm` or `agent_chat/mlx`: what Dart asks for, and the
/// door Swift's `send` knocks on. The real channels have no implementation on
/// a test host. The channel under the mock is the export itself
/// ([appleChannel], [mlxChannel]), so a name drift on the port is a compile
/// error at the test rather than a hung test.
class ChannelMock {
  ChannelMock(this.channel);

  final MethodChannel channel;

  /// Every call Dart made, in order.
  final asked = <MethodCall>[];

  /// What a call is answered with; throwing is how Swift refuses one.
  Object? Function(MethodCall call) answer = (_) => null;

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        asked.add(call);
        return answer(call);
      });

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    asked.clear();
    answer = (_) => null;
  }

  /// A frame from Swift, delivered through the bridge.
  Future<void> incoming(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, arguments)),
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
