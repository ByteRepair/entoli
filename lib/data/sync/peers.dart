import "dart:async";

import "package:flutter/foundation.dart";

import "../../core/log.dart";
import "../../domain/sync/devices.dart";
import "../../domain/sync/protocol.dart";
import "framing.dart";

enum PeerStatus { connecting, online, offline, error }

/// A paired device as the Sync page draws it. By value, so republishing the
/// same list is not a change — the page copies and sorts on every one.
class PeerState {
  PeerState({
    required this.deviceId,
    required this.name,
    required this.status,
    this.error,
  });

  final String deviceId;
  final String name;
  final PeerStatus status;
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is PeerState &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.status == status &&
      other.error == error;

  @override
  int get hashCode => Object.hash(deviceId, name, status, error);
}

/// One live connection, and the queue that keeps a peer's messages in the
/// order they arrived.
class LivePeer {
  LivePeer(this.channel,
      {required this.deviceId,
      required this.deviceName,
      required this._onClose});

  final SecureChannel channel;
  final String deviceId;
  final String deviceName;
  final void Function() _onClose;
  bool _closed = false;

  DateTime lastPong = DateTime.now();

  /// This device's chat ids the peer is following. Only subscribers get
  /// record and state pushes.
  final subscriptions = <String>{};

  StreamSubscription<Map<String, dynamic>>? pump;

  /// Handlers await disk I/O, so messages are chained through this to keep
  /// their arrival order — a snapshot must land before the appends that
  /// follow it.
  Future<void> _queue = Future.value();

  void enqueue(SyncMessage message) {
    if (_closed) return;
    _queue = _queue.then((_) => handle?.call(message)).catchError((Object error) =>
        logFailure("sync", "handling a message from $deviceId", error));
  }

  /// Set once the peer exists; reads the hub's dispatcher.
  void Function(SyncMessage message)? handle;

  /// A send that throws is a connection that has gone. Dropping the peer is
  /// the only thing to do with that, and letting the error out instead turns
  /// one vanishing mid-broadcast into an unhandled exception in whichever
  /// loop happened to be writing to it.
  Future<void> send(SyncMessage message) async {
    if (_closed) return;
    try {
      await channel.sendJson(message.toJson());
    } catch (error) {
      // Almost always a message the transport refused as too large, which is
      // silent otherwise: the peer simply goes away.
      logFailure("sync", "send to $deviceId failed", error);
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await pump?.cancel();
    await channel.close();
    _onClose();
  }
}

/// Who is connected, and what this device is serving them.
///
/// The piece both halves of sync stand on: [SyncPairing] puts a peer here,
/// and everything [SyncHub] does with a chat reads or writes through one. It
/// owns the connections and the status the Sync page draws, and nothing else.
class SyncPeers {
  SyncPeers(this._registry);

  final DeviceRegistry _registry;
  final _live = <String, LivePeer>{};

  /// Every paired device and whether it is reachable. Not only the connected
  /// ones: [publish] seeds the registry's at startup, so the page has a list
  /// from the first frame.
  final states = ValueNotifier<Map<String, PeerState>>({});

  /// Chats of this device that some peer is watching. The serving side keeps
  /// a controller open per entry, which is what makes a turn's progress
  /// visible at the other end.
  final servedChats = ValueNotifier<Set<String>>(const {});

  Timer? _pingTimer;

  Iterable<LivePeer> get live => _live.values;

  bool get isEmpty => _live.isEmpty;

  LivePeer? operator [](String deviceId) => _live[deviceId];

  bool hasLive(String? deviceId) => _live.containsKey(deviceId);

  /// Whether [status] is a connection — held, or being established. The
  /// answer is this class's because the statuses are: a dial counts, since
  /// the moment a hold is wanted most is the one before the channel exists.
  static bool connected(PeerStatus status) =>
      status == PeerStatus.online || status == PeerStatus.connecting;

  void adopt(LivePeer peer) {
    _live[peer.deviceId]?.close();
    _live[peer.deviceId] = peer;
  }

  LivePeer? remove(String deviceId) => _live.remove(deviceId);

  /// To every peer following [chatId], so an arm carrying a chat's contents
  /// cannot forget the subscription check. What reaches everyone instead — a
  /// deletion, the chat list — loops [live] itself and says so there.
  void toSubscribers(String chatId, SyncMessage message) {
    for (final peer in _live.values) {
      if (peer.subscriptions.contains(chatId)) unawaited(peer.send(message));
    }
  }

  void setStatus(String deviceId,
      {required String name, required PeerStatus status, String? error}) {
    final next = {
      ...states.value,
      deviceId: PeerState(
          deviceId: deviceId, name: name, status: status, error: error),
    };
    if (!mapEquals(next, states.value)) states.value = next;
  }

  void markOffline(String deviceId) {
    final existing = states.value[deviceId];
    if (existing == null || existing.status == PeerStatus.error) return;
    setStatus(deviceId, name: existing.name, status: PeerStatus.offline);
  }

  void forget(String deviceId) =>
      states.value = {...states.value}..remove(deviceId);

  Future<void> refresh() async => publish(await _registry.list());

  /// Fills in the paired-but-not-connected. Only gaps: a device that is
  /// online here must not be demoted by a registry read.
  void publish(List<PairedDevice> devices) {
    final next = {...states.value};
    for (final device in devices) {
      next.putIfAbsent(
        device.id,
        () => PeerState(
            deviceId: device.id,
            name: device.name,
            status: PeerStatus.offline),
      );
    }
    if (!mapEquals(next, states.value)) states.value = next;
  }

  void refreshServed() {
    final served = {for (final peer in _live.values) ...peer.subscriptions};
    if (!setEquals(served, servedChats.value)) servedChats.value = served;
  }

  /// Thirty seconds of silence gets a ping; seventy-five without an answer is
  /// a connection that has gone whether or not the socket says so.
  void watchLiveness() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final cutoff = DateTime.now().subtract(const Duration(seconds: 75));
      for (final peer in _live.values.toList()) {
        if (peer.lastPong.isBefore(cutoff)) {
          unawaited(peer.close());
          continue;
        }
        unawaited(peer.send(const SyncMessage.ping()));
      }
    });
  }

  Future<void> dispose() async {
    _pingTimer?.cancel();
    // Over a copy: closing a peer takes it back out of the map.
    for (final peer in _live.values.toList()) {
      await peer.close();
    }
    _live.clear();
    servedChats.value = const {};
  }
}
