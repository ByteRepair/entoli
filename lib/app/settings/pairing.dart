import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/pairing.dart" show PairingActivity;
import "../../data/sync/sync_hub.dart" show SyncHub;
import "../../providers.dart" show syncHubProvider;

export "../../data/sync/pairing.dart" show PairingActivity, PairingStage;

/// Pairing another device, as every frontend drives it: a window this
/// device shows a code in, an invite pasted across by hand, or a code from
/// the other device; then the codes both screens show, confirmed matching,
/// and paired or failed — [activity] says which, as it changes.
class PairingFlow {
  const PairingFlow(this._hub);

  final SyncHub _hub;

  /// The pairing in flight, or null.
  ValueListenable<PairingActivity?> get activity => _hub.pairing;

  Future<void> openWindow() => _hub.startPairingWindow();

  void closeWindow() => _hub.cancelPairingWindow();

  /// The invite to send the other device by hand.
  Future<String> createInvite() => _hub.createManualInvite();

  void cancelInvite() => _hub.cancelManualInvite();

  /// Pairs with the code or the answer the other device gave.
  Future<String?> join(String code) => _hub.pairWith(code.trim());

  /// Whether the codes both devices show match.
  void confirm(bool match) => _hub.confirmPairing(match);

  void cancel() => _hub.cancelPairing();
}

final pairingFlowProvider = Provider<PairingFlow>(
  (ref) => PairingFlow(ref.watch(syncHubProvider)),
);
