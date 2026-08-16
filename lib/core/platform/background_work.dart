import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/background_work.dart";

/// Android's foreground service, on the other end of `agent_chat/background`
/// and implemented by `AgentService.kt`. Not behind the conditional import, for
/// the same reason `LauncherAliases` is not: a `MethodChannel` compiles on
/// every platform, and one with nothing answering it throws
/// `MissingPluginException` — which is the no-op every other platform wants, so
/// there is no need to ask which platform this is.
class ForegroundService implements BackgroundWork {
  ForegroundService() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/background");

  final _stops = StreamController<void>.broadcast();

  @override
  Stream<void> get stopRequests => _stops.stream;

  @override
  Future<void> running(int turns) async {
    // Logged rather than raised: a platform that will not hold the process
    // leaves a turn where every other platform's already is, and a refusal
    // otherwise looks exactly like a turn dying for no reason.
    try {
      await _channel.invokeMethod<void>("running", turns);
    } on PlatformException catch (e) {
      debugPrint("Background work not held: $e");
    } on MissingPluginException catch (_) {}
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method == "stopRequested") _stops.add(null);
  }
}
