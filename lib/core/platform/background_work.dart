import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../domain/background_work.dart";

/// Android's foreground services, on the other end of `agent_chat/background`
/// and implemented by `ForegroundWork.kt` and the three services beside it. Not
/// behind the conditional import, for the same reason `LauncherAliases` is not:
/// a `MethodChannel` compiles on every platform, and one with nothing answering
/// it throws `MissingPluginException` — which is the no-op every other platform
/// wants, so there is no need to ask which platform this is.
class ForegroundService implements BackgroundWork {
  ForegroundService() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel("agent_chat/background");

  final _stops = StreamController<BackgroundJob>.broadcast();

  @override
  Stream<BackgroundJob> get stopRequests => _stops.stream;

  @override
  Future<void> running(int turns) => _tell("running", turns);

  @override
  Future<void> listening(bool active) => _tell("listening", active);

  @override
  Future<void> downloading(DownloadNotice? notice) => _tell(
        "downloading",
        notice == null
            ? null
            : {
                "label": notice.label,
                "received": notice.received,
                "total": notice.total,
              },
      );

  Future<void> _tell(String method, Object? argument) async {
    // Logged rather than raised: a platform that will not hold the process
    // leaves the work where every other platform's already is, and a refusal
    // otherwise looks exactly like a turn dying for no reason.
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on PlatformException catch (e) {
      debugPrint("Background work not held: $e");
    } on MissingPluginException catch (_) {}
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != "stopRequested") return;
    final job = BackgroundJob.values.asNameMap()[call.arguments as String? ?? ""];
    if (job != null) _stops.add(job);
  }
}
