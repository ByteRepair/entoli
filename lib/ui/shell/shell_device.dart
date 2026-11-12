import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../data/sync/peers.dart";
import "../../domain/sync/devices.dart";
import "../../providers.dart";

/// A paired device's page in the native settings: the device sent while the
/// client shows it, and what the client can do there. The Flutter frontend's
/// `PairedDevicePage` reads the same hub.
class ShellDevicePage {
  ShellDevicePage(this._container, this._native);

  final ProviderContainer _container;
  final NativeSettings _native;

  /// The device whose page is shown, as its connection moves. A rename
  /// arrives here too, being the peer's name.
  ProviderSubscription<PeerState?>? _watching;

  void show(String? id) {
    _watching?.close();
    _watching = null;
    if (id == null) return;
    _watching = _container.listen<PeerState?>(
      syncPeersProvider.select((peers) => peers[id]),
      // The record is read again on each: a dial that ends writes when the
      // device was last seen.
      (_, peer) => unawaited(_send(id, peer)),
      fireImmediately: true,
    );
  }

  Future<void> _send(String id, PeerState? peer) async {
    final hub = _container.read(syncHubProvider);
    PairedDeviceData? data;
    String? readError;
    try {
      final device = await hub.registry.byId(id);
      if (device != null) data = _data(device, peer, hub.identity.fingerprint);
    } catch (e) {
      // Said on the page, not dropped: "no longer paired" would be false.
      readError = "$e";
    }
    try {
      await _native.device(id, data, readError);
    } catch (e) {
      logFailure("settings", "sending device $id", e);
    }
  }

  static PairedDeviceData _data(
    PairedDevice device,
    PeerState? peer,
    String own,
  ) => PairedDeviceData(
    id: device.id,
    name: peer?.name ?? device.name,
    // A device the hub has not published yet is one it has not reached.
    status: switch (peer?.status ?? PeerStatus.offline) {
      PeerStatus.connecting => DeviceStatus.connecting,
      PeerStatus.online => DeviceStatus.online,
      PeerStatus.offline => DeviceStatus.offline,
      PeerStatus.error => DeviceStatus.error,
    },
    error: peer?.error,
    lastSeenMs: device.lastSeenAt.millisecondsSinceEpoch,
    addedMs: device.addedAt.millisecondsSinceEpoch,
    addresses: device.addresses,
    fingerprint: device.fingerprint,
    ownFingerprint: own,
  );

  Future<SettingNoticeData?> act(String id, DeviceOp op, String? name) async {
    final hub = _container.read(syncHubProvider);
    try {
      await switch (op) {
        DeviceOp.connect => hub.connect(id),
        DeviceOp.disconnect => hub.disconnect(id),
        DeviceOp.rename when name != null => hub.rename(id, name),
        DeviceOp.rename => Future<void>.value(),
        DeviceOp.revoke => hub.revoke(id),
      };
      return null;
    } catch (e) {
      return SettingNoticeData(message: "$e");
    }
  }

  void close() => show(null);
}
