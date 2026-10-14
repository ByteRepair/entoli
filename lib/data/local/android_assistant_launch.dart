import "dart:async";

import "package:flutter/services.dart";

import "../../domain/assistant_launch.dart";

/// Android, where the system's assistant gesture arrives as an `ACTION_ASSIST`
/// intent that `AssistantChannel.kt` notices on the other end of
/// `agent_chat/assistant`.
///
/// Kotlin holds the launch rather than pushing it, because the gesture is
/// usually what starts the app and Dart is not listening for a good while after
/// that — so [take] is the startup read and [launched] is the nudge for one
/// arriving into an app already up. `FilesChannel` splits a share the same way,
/// and both halves are needed for the same reason.
class AndroidAssistantLaunch implements AssistantLaunch {
  AndroidAssistantLaunch() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/assistant");

  final _arrived = StreamController<void>.broadcast();

  @override
  bool get hasGesture => true;

  @override
  Stream<void> get launched => _arrived.stream;

  @override
  Future<bool> take() async =>
      await _channel.invokeMethod<bool>("takeLaunch") ?? false;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == "assist") _arrived.add(null);
  }
}
