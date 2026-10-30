import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/date_words.dart";
import "../../domain/sync/devices.dart";
import "../../providers.dart";
import "../fonts.dart" show monoFamily;
import "../widgets/dialogs.dart";
import "../widgets/section_header.dart";

/// The verbatim values' face: this page's fingerprints and last address
/// render in the bundled mono, not the platform alias the rest of the sync
/// screens' older literals spell.
const _monoStyle = TextStyle(fontFamily: monoFamily, fontSize: 13);

/// How a connection reads on screen. The paired-device row on the Sync page
/// and the device's own page below share the icon and the colour — one home
/// so the two cannot drift; the word is the page's alone, private for it.
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

String _peerStatusWord(PeerStatus status) => switch (status) {
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
      final device = await ref
          .read(syncHubProvider)
          .registry
          .byId(widget.deviceId);
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

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(syncHubProvider);
    // One device's state, and only that device's: the page is rebuilt when
    // its own name, status or error moves, not when an unrelated device's
    // dial does.
    final peer = ref.watch(
      syncPeersProvider.select((peers) => peers[widget.deviceId]),
    );
    final device = _device;
    final theme = Theme.of(context);
    // The record's fresh half is what this page's own Connect writes — a
    // dial that ends marks the device seen. The one change worth re-reading
    // for, answered when the status settles rather than as a comment.
    ref.listen(
      syncPeersProvider.select((peers) => peers[widget.deviceId]?.status),
      (_, status) {
        if (status != PeerStatus.connecting) _reload();
      },
    );

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
  List<Widget> _content(
    SyncHub hub,
    PairedDevice device,
    PeerState? peer,
    ThemeData theme,
  ) {
    final name = peer?.name ?? device.name;
    final status =
        peer?.status ?? PeerStatus.offline; // published at every startup.
    final peerFingerprint = device.fingerprint;
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
        leading: Icon(
          peerStatusIcon(status),
          size: 20,
          color: peerStatusColor(status, theme),
        ),
        title: Text(_peerStatusWord(status)),
        subtitle: peer?.error == null ? null : SelectableText(peer!.error!),
        // The row's action, beside the status it acts on. Connecting is the
        // wait's own state; a dial that finds nothing is said on this page.
        trailing: status == PeerStatus.connecting
            ? null
            : status == PeerStatus.online
            ? TextButton(
                onPressed: () =>
                    catchAndSay(context, () => hub.disconnect(widget.deviceId)),
                child: const Text("Disconnect"),
              )
            : TextButton(
                onPressed: () =>
                    catchAndSay(context, () => hub.connect(widget.deviceId)),
                child: const Text("Connect"),
              ),
      ),
      ListTile(
        title: const Text("Last connected"),
        subtitle: Text(describeFire(device.lastSeenAt, DateTime.now())),
      ),
      if (device.addresses.isNotEmpty)
        ListTile(
          title: const Text("Last addresses"),
          subtitle: Text(device.addresses.join("\n"), style: _monoStyle),
        ),
      ListTile(
        title: const Text("Paired"),
        subtitle: Text(describeFire(device.addedAt, DateTime.now())),
      ),
      const Divider(),
      // The peer's key, as this device stores it.
      SectionHeader(
        "Device fingerprint",
        description:
            "The code over $name's sync key, as this device "
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
        child: mutedParagraph(
          context,
          "A fingerprint is a code derived from a device's sync key. It is "
          "not a secret: it identifies a key and grants nothing. "
          "Connecting still requires a pairing code. To verify the pair, "
          "compare the Device fingerprint above with the code $name shows "
          "under This device on its own Sync page. Matching codes mean the "
          "two devices are still the ones that completed the pairing.",
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
                context,
                name,
                () => hub.revoke(widget.deviceId),
              );
              if (ok && mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.link_off),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            label: const Text("Revoke"),
          ),
        ),
      ),
    ];
  }
}

/// Revoking asks first, wherever it is asked from. The row on the Sync page
/// and the device's own page share this one dialog, so the two wordings (and
/// the promise about what a revoke does not do) cannot drift apart; the
/// revoke's own failure is its catch, where the row's connect and disconnect
/// go through `catchAndSay` — [say]'s rule holds for every verb under a
/// button. False leaves both surfaces as they were: not revoked, not popped.
Future<bool> confirmRevokeDevice(
  BuildContext context,
  String name,
  Future<void> Function() revoke,
) async {
  final ok = await confirm(
    context,
    title: "Revoke device?",
    message:
        "Unpair from $name? They will keep this device until someone "
        "revokes there too.",
    confirmLabel: "Revoke",
    destructive: true,
  );
  if (!ok) return false;
  try {
    await revoke();
  } catch (error) {
    if (context.mounted) say(context, error);
    return false;
  }
  return true;
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
          Icon(
            Icons.fingerprint_outlined,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: _monoStyle)),
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
