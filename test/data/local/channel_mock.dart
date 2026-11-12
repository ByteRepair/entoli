import "dart:async";

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

  /// Each call as it is made, for [until] to wait on.
  final _calls = StreamController<MethodCall>.broadcast(sync: true);

  /// What a call is answered with; throwing is how Swift refuses one.
  Object? Function(MethodCall call) answer = (_) => null;

  void install() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        asked.add(call);
        _calls.add(call);
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
    await Future<void>.delayed(Duration.zero);
  }

  /// Until Dart has called [method], for a request that sits behind other
  /// channel round trips and real file I/O: waited on as the call itself,
  /// since no count of event-loop turns covers a loaded machine's disk.
  Future<void> until(String method) async {
    if (asked.any((call) => call.method == method)) return;
    await _calls.stream.firstWhere((call) => call.method == method);
  }

  /// The one call to [method], as its arguments.
  Map<Object?, Object?> outgoing(String method) => asked
      .where((call) => call.method == method)
      .map((call) => call.arguments as Map<Object?, Object?>)
      .single;
}
