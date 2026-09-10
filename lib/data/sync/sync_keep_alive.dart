import "dart:async";

import "../../domain/background_work.dart";
import "sync_hub.dart";

/// Holds the platform's background permission for as long as a paired device
/// is connected and the keep-alive setting is on — what keeps the WebRTC
/// channel through the screen going dark on Android. Reads the setting live
/// the way the hub reads its own: the switch reaches the next change, and a
/// connection held at the moment it is turned off is released by the same
/// change.
///
/// Nothing addresses one: it is read into being by `syncKeepAliveProvider`
/// and thereafter listens.
class SyncKeepAlive {
  SyncKeepAlive(this._hub, this._work, {required this._keepAlive}) {
    _hub.peers.addListener(_changed);
    _stops = _work.stopRequests
        .where((job) => job == BackgroundJob.sync)
        .listen((_) => _disconnectAll());
  }

  final SyncHub _hub;
  final BackgroundWork _work;
  final bool Function() _keepAlive;
  late final StreamSubscription<void> _stops;

  /// The connected devices last reported, so a keep-alive turned off
  /// mid-connection still knows who Disconnect-all is for.
  List<PeerState> _connected = const [];

  void _changed() {
    _connected = [
      for (final peer in _hub.peers.value.values)
        if (peer.status == PeerStatus.online ||
            peer.status == PeerStatus.connecting)
          peer,
    ];
    final on = _keepAlive() && _connected.isNotEmpty;
    unawaited(_work.syncing(
      !on
          ? null
          : SyncNotice(
              count: _connected.length,
              devices: _connected.map((peer) => peer.name).join("\n"),
            ),
    ));
  }

  /// The notification's Disconnect: the same call the Sync page's row makes,
  /// which is what drops the statuses and so releases the service. Asked
  /// while nothing is connected it is nothing to do.
  Future<void> _disconnectAll() =>
      Future.wait(_connected.map((peer) => _hub.disconnect(peer.deviceId)));

  void dispose() {
    _hub.peers.removeListener(_changed);
    unawaited(_stops.cancel());
  }
}