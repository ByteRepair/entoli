import "dart:async";

import "agent_backend.dart";
import "background_work.dart";

/// Holds the platform's background permission for as long as a turn is running,
/// and answers the Stop it offers in return. Nothing addresses one: it is read
/// into being by `turnKeepAliveProvider` and thereafter listens.
class TurnKeepAlive {
  TurnKeepAlive(this._backend, this._work) {
    _backend.runningTurns.addListener(_changed);
    _stops = _work.stopRequests.listen((_) => _stopAll());
  }

  final AgentBackend _backend;
  final BackgroundWork _work;
  late final StreamSubscription<void> _stops;

  void _changed() => unawaited(_work.running(_backend.runningTurns.value.length));

  Future<void> _stopAll() =>
      Future.wait(_backend.runningTurns.value.map(_backend.abort));

  void dispose() {
    _backend.runningTurns.removeListener(_changed);
    unawaited(_stops.cancel());
  }
}
