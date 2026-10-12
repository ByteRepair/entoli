import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/date_words.dart";
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "../widgets/section_header.dart";

/// How a connection status reads on screen, shared by the paired-device row
/// on the Sync page and by the device's own page below — one home so the row
/// and the page cannot drift.
IconData peerStatusIcon(PeerStatus status) => switch (status) {
      PeerStatus.online => Icons.circle,
      PeerStatus.connecting => Icons.circle_outlined,
      PeerStatus.offline => Icons.circle_outlined,
      PeerStatus.error => Icons.error_outline,
    };

Color peerStatusColor(PeerStatus status, ThemeData theme) => switch (status) {
      PeerStatus.online => Colors.green,
      PeerStatus.connecting => theme.colorScheme.primary,
      PeerStatus.offline => theme.colorScheme.onSurfaceVariant,
      PeerStatus.error => theme.colorScheme.error,
    };

String peerStatusWord(PeerStatus status) => switch (status) {
      PeerStatus.online => "Connected",
      PeerStatus.connecting => "Connecting…",
      PeerStatus.offline => "Not connected",
      PeerStatus.error => "Not connected",
    };

/// A paired device's own page, reached by clicking its row on the Sync page:
/// the record as this device holds it — the name, the connection, when it
/// was last reached — with the rename beside it, and then the two
/// fingerprints a pair exists to compare.
class PairedDevicePage extends ConsumerStatefulWidget {
  const PairedDevicePage({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<PairedDevicePage> createState() => _PairedDevicePageState();
}

class _PairedDevicePageState extends ConsumerState<PairedDevicePage> {
  /// The record, read once. A name change travels through [PeerState] instead
  /// — the rename updates both sides — and everything else here only changes
  /// at a reconnect, where being on this page is the odd case.
  PairedDevice? _device;
  bool _loaded = false;
  String? _readError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final device =
          await ref.read(syncHubProvider).registry.byId(widget.deviceId);
      if (mounted) {
        setState(() {
          _device = device;
          _readError = null;
          _loaded = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _readError = "$error";
          _loaded = true;
        });
      }
    }
  }

  Future<void> _rename(String current) async {
    final next = await promptForText(
      context,
      title: "Rename $current",
      initial: current,
      confirmLabel: "Rename",
    );
    if (!mounted || next == null || next == current) return;
    try {
      await ref.read(syncHubProvider).rename(widget.deviceId, next);
    } catch (error) {
      // A registry write that could not get through is said, not dropped:
      // an unawaited failure under a pressed button does nothing on screen.
      if (mounted) say(context, error);
    }
  }

  /// A dial that could not find the device is said on this page, not left as
  /// an unhandled error under a pressed button — the row's own rule, here for
  /// its Connect and Disconnect.
  void _tried(Future<void> Function() work) =>
      unawaited(work().catchError((Object error) {
        if (mounted) say(context, error);
      }));

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(syncHubProvider);
    final peer = ref.watch(syncPeersProvider)[widget.deviceId];
    final device = _device;
    final theme = Theme.of(context);

    // The header stays a category ("Paired device"); the name it would have
    // repeated sits one line down, and a title saying who this is a page
    // about would show it twice on a screen this short.
    return Scaffold(
      appBar: AppBar(title: const Text("Paired device")),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : device == null
              // Revoked (there as here) while the page was open: the record
              // went. A read that could not get through says what did not;
              // the answer would otherwise be the same false "gone".
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SelectableText(
                      _readError != null
                          ? "The record could not be read: $_readError"
                          : "No longer paired.",
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: _content(hub, device, peer, theme),
                ),
    );
  }

  // The state's own context: the closures below cross async gaps, and a
  // context guarded by `mounted` is this class's to guard.
  List<Widget> _content(SyncHub hub, PairedDevice device, PeerState? peer,
      ThemeData theme) {
    final name = peer?.name ?? device.name;
    final status =
        peer?.status ?? PeerStatus.offline; // published at every startup.
    final peerFingerprint = fingerprintOfB64(device.publicKey);
    return [
      // The name as this device files it, and the rename beside it. Nothing
      // here renames the peer itself: names are each side's own.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(
          children: [
            Expanded(child: Text(name, style: theme.textTheme.titleLarge)),
            TextButton.icon(
              onPressed: () => _rename(name),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text("Rename"),
            ),
          ],
        ),
      ),
      ListTile(
        leading: Icon(peerStatusIcon(status),
            size: 20, color: peerStatusColor(status, theme)),
        title: Text(peerStatusWord(status)),
        subtitle: peer?.error == null ? null : Text(peer!.error!),
        // The row's action, beside the status it acts on. Connecting is the
        // wait's own state; a dial that finds nothing is said on this page.
        trailing: status == PeerStatus.connecting
            ? null
            : status == PeerStatus.online
                ? TextButton(
                    onPressed: () => _tried(
                        () => hub.disconnect(widget.deviceId)),
                    child: const Text("Disconnect"))
                : TextButton(
                    onPressed: () =>
                        _tried(() => hub.connect(widget.deviceId)),
                    child: const Text("Connect")),
      ),
      ListTile(
        title: const Text("Last connected"),
        subtitle: Text(describeFire(device.lastSeenAt, DateTime.now())),
      ),
      if (device.lastAddress != null)
        ListTile(
          title: const Text("Last address"),
          subtitle: Text(device.lastAddress!,
              style: const TextStyle(fontFamily: "monospace", fontSize: 13)),
        ),
      ListTile(
        title: const Text("Paired"),
        subtitle: Text(describeFire(device.addedAt, DateTime.now())),
      ),
      const Divider(),
      // The peer's key, as this device stores it.
      SectionHeader(
        "Device fingerprint",
        description: "The code over $name's sync key, as this device "
            "received it at the pair.",
      ),
      if (peerFingerprint case final fingerprint?)
        _FingerprintLine(fingerprint)
      else
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text("The stored key is not a decodable key."),
        ),
      const Divider(),
      // This device's own — the other side of the same comparison.
      SectionHeader("This device"),
      _FingerprintLine(hub.identity.fingerprint),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          "A fingerprint is a code derived from a device's sync key. It is "
          "not a secret: it identifies a key and grants nothing. Connecting "
          "still requires a pairing code. To verify the pair, compare the "
          "Device fingerprint above with the code $name shows under This "
          "device on its own Sync page. Matching codes mean the two devices "
          "are still the ones that completed the pairing.",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      // The row's destructive action, at the end of the page the way a
      // destructive action ends a page. A successful one leaves nothing for
      // this screen to stand in for.
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: () async {
              final ok = await confirmRevokeDevice(
                  context, name, () => hub.revoke(widget.deviceId));
              if (ok && mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.link_off),
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            label: const Text("Revoke"),
          ),
        ),
      ),
    ];
  }
}

/// The fingerprint of a stored key, or null where it will not decode — a
/// record this device wrote, so only a hand-edit could break it.
String? fingerprintOfB64(String publicKeyB64) {
  try {
    return SyncIdentity.fingerprintOf(base64Decode(publicKeyB64));
  } catch (_) {
    return null;
  }
}

/// Revoking asks first, wherever it is asked from. The row on the Sync page
/// and the device's own page share this one dialog, so the two wordings (and
/// the promise about what a revoke does not do) cannot drift apart.
Future<bool> confirmRevokeDevice(
  BuildContext context,
  String name,
  Future<void> Function() revoke,
) async {
  final ok = await confirm(
    context,
    title: "Revoke device?",
    message: "Unpair from $name? They will keep this device until someone "
        "revokes there too.",
    confirmLabel: "Revoke",
    destructive: true,
  );
  if (ok) await revoke();
  return ok;
}

/// A fingerprint as a row: the key icon, the grouped hex, and the copy
/// affordance. One shape for both fingerprints, so neither looks like more.
class _FingerprintLine extends StatelessWidget {
  const _FingerprintLine(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.fingerprint_outlined,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: "monospace", fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: "Copy fingerprint",
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () =>
                copyToClipboard(context, value, said: "Fingerprint copied"),
          ),
        ],
      ),
    );
  }
}
