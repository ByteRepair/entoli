import "dart:async";

import "../../domain/background_work.dart";
import "sync_hub.dart";

/// Holds the platform's background permission for as long as a paired device
/// is connected and the keep-alive setting is on — what keeps the WebRTC
/// channel through the screen going dark on Android. Reads the setting live
/// the way the hub reads its own, and through [refresh] the moment the switch
/// moves rather than waiting for a status to move first.
///
/// Nothing addresses one: it is read into being by `syncKeepAliveProvider`
/// and thereafter listens.
class SyncKeepAlive {
  SyncKeepAlive(this._hub, this._work, {required this._keepAlive}) {
    _hub.peers.addListener(_peersChanged);
    _stops = _work.stopRequests
        .where((job) => job == BackgroundJob.sync)
        .listen((_) => _disconnectAll());
  }

  final SyncHub _hub;
  final BackgroundWork _work;
  final bool Function() _keepAlive;
  late final StreamSubscription<void> _stops;

  /// The last notice, so a peers change that reports the same thing does not
  /// cross the channel again. Null is both "never reported" and "reporting
  /// nothing", which is the same answer: the platform starts holding nothing.
  SyncNotice? _last;

  /// The connected devices right now, by id — what Disconnect-all is for.
  Map<String, String> get _connected => {
    for (final peer in _hub.peers.value.values)
      if (SyncPeers.connected(peer.status)) peer.deviceId: peer.name,
  };

  void _peersChanged() => unawaited(_report());

  /// Re-reads the peers and the setting. A change in what it answers is one
  /// call; the rest — the failing dial of a device the hold never covered, a
  /// registry seed, the switch off with nothing connected — is free.
  Future<void> refresh() => _report();

  Future<void> _report() async {
    final on = _keepAlive() && _connected.isNotEmpty;
    final notice = on ? SyncNotice(names: _connected.values.toList()) : null;
    if (_last == notice) return;
    _last = notice;
    await _work.syncing(notice);
  }

  /// The notification's Disconnect: the same call the Sync page's row makes,
  /// which is what drops the statuses and so releases the service. Asked
  /// while nothing is connected it is nothing to do.
  Future<void> _disconnectAll() =>
      Future.wait(_connected.keys.map(_hub.disconnect));

  void dispose() {
    _hub.peers.removeListener(_peersChanged);
    unawaited(_stops.cancel());
  }
}
