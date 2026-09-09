import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:mobile_scanner/mobile_scanner.dart";
import "package:qr_flutter/qr_flutter.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/app_settings.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The Sync category: this device's identity and name, then how to pair a new
/// device, the paired-device list, and the relay and TURN settings for reaching
/// peers over the internet. Shown on every platform — a browser pairs as the
/// joiner side, so the identity and the paired-device list are still its
/// business.
class SyncSection extends ConsumerWidget {
  const SyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final hub = ref.watch(syncHubProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Sync",
          description: "Pair with another device to mirror chats and take "
              "remote control. Chats stay on their home device; a mirror is "
              "RAM-only and never written to disk.",
        ),
        _IdentityField(hub: hub),
        LabelledField(
          label: "Device name",
          child: ResettableField(
            onReset: () =>
                ref.read(appSettingsProvider.notifier).setDeviceName(null),
            child: TextFormField(
              initialValue: settings.deviceName ?? "",
              decoration: InputDecoration(
                // The name the other device would file this one under with
                // nothing typed here, rather than a stand-in for it.
                hintText: hub.defaultDeviceName,
                isDense: true,
              ),
              onChanged: (value) => ref
                  .read(appSettingsProvider.notifier)
                  .setDeviceName(value.isEmpty ? null : value),
            ),
          ),
        ),
        Divider(),
        ValueListenableBuilder(
          valueListenable: hub.pairing,
          builder: (context, pairing, _) => pairing == null
              ? _PairingControls(hub: hub)
              : _PairingStatus(pairing: pairing, hub: hub),
        ),
        Divider(),
        _PairedDevices(hub: hub),
        Divider(),
        _RelaySection(settings: settings),
        Divider(),
        _TurnSection(settings: settings),
      ],
    );
  }
}

class _IdentityField extends StatelessWidget {
  const _IdentityField({required this.hub});

  final SyncHub hub;

  @override
  Widget build(BuildContext context) {
    return LabelledField(
      label: "This device",
      child: Row(
        children: [
          Icon(Icons.fingerprint_outlined,
              size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hub.identity.fingerprint,
              style: const TextStyle(fontFamily: "monospace", fontSize: 13),
            ),
          ),
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text("relay / manual only",
                  style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

class _RelaySection extends ConsumerWidget {
  const _RelaySection({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Internet relay",
          description: "A WebSocket relay for pairing over the internet. Both "
              "devices dial the same room, derived from the pairing secret — "
              "the relay sees nothing readable.",
        ),
        LabelledField(
          label: "Relay URL",
          child: TextFormField(
            initialValue: settings.syncRelayUrl ?? "",
            decoration: const InputDecoration(
              hintText: "wss://relay.example.com",
              isDense: true,
            ),
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setSyncRelayUrl(value.isEmpty ? null : value),
          ),
        ),
      ],
    );
  }
}

class _TurnSection extends ConsumerWidget {
  const _TurnSection({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "TURN server",
          description: "For NAT traversal. Bring your own — a self-hosted "
              "coturn is recommended. Without one, symmetric-NAT pairs fail "
              "honestly.",
        ),
        LabelledField(
          label: "TURN URL",
          child: TextFormField(
            initialValue: settings.turnUrl ?? "",
            decoration: const InputDecoration(
              hintText: "turn:turn.example.com:3478",
              isDense: true,
            ),
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setTurnUrl(value.isEmpty ? null : value),
          ),
        ),
        LabelledField(
          label: "TURN username",
          child: TextFormField(
            initialValue: settings.turnUsername ?? "",
            decoration: const InputDecoration(isDense: true),
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setTurnUsername(value.isEmpty ? null : value),
          ),
        ),
        LabelledField(
          label: "TURN password",
          child: TextFormField(
            // Held in the secret store, not settings — read through the
            // mirror here the way the row above reads its own field.
            initialValue: ref.read(appSecretsProvider).turnPassword ?? "",
            obscureText: true,
            decoration: const InputDecoration(isDense: true),
            onChanged: (value) => ref
                .read(appSecretsProvider)
                .setTurnPassword(value.isEmpty ? null : value),
          ),
        ),
      ],
    );
  }
}

class _PairedDevices extends ConsumerWidget {
  const _PairedDevices({required this.hub});

  final SyncHub hub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One source for both membership and status. Reading the registry here
    // instead meant a device paired while this page was open did not appear
    // until the page was left and come back to.
    final peers = ref.watch(syncPeersProvider).values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Paired devices",
          description: peers.isEmpty
              ? "No devices paired yet. Pair a new device above."
              : null,
        ),
        for (final peer in peers)
          _PairedDeviceRow(
            peer: peer,
            onRevoke: () => hub.revoke(peer.deviceId),
            onConnect: () => hub.connect(peer.deviceId),
            onDisconnect: () => hub.disconnect(peer.deviceId),
            onFailed: (error) => say(context, error),
          ),
      ],
    );
  }
}

class _PairedDeviceRow extends StatelessWidget {
  const _PairedDeviceRow({
    required this.peer,
    required this.onRevoke,
    required this.onConnect,
    required this.onDisconnect,
    required this.onFailed,
  });

  final PeerState peer;
  final Future<void> Function() onRevoke;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  /// A dial that could not find the device. Reported here rather than left to
  /// the future nobody awaits: `onPressed` takes a `VoidCallback`, so an
  /// unawaited failure is an unhandled error and a button that did nothing.
  final void Function(Object error) onFailed;

  @override
  Widget build(BuildContext context) {
    final status = peer.status;
    final theme = Theme.of(context);
    final failure = peer.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(status), size: 16, color: _colorFor(status, theme)),
              const SizedBox(width: 8),
              Expanded(child: Text(peer.name)),
              if (status == PeerStatus.online)
                TextButton(
                    onPressed: () => _tried(onDisconnect),
                    child: const Text("Disconnect"))
              else
                TextButton(
                    onPressed: status == PeerStatus.connecting
                        ? null
                        : () => _tried(onConnect),
                    child: const Text("Connect")),
              TextButton(
                onPressed: () => _confirmRevoke(context),
                style:
                    TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                child: const Text("Revoke"),
              ),
            ],
          ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 8),
              child: Text(
                failure,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  void _tried(Future<void> Function() work) =>
      unawaited(work().catchError(onFailed));

  IconData _iconFor(PeerStatus status) => switch (status) {
        PeerStatus.online => Icons.circle,
        PeerStatus.connecting => Icons.circle_outlined,
        PeerStatus.offline => Icons.circle_outlined,
        PeerStatus.error => Icons.error_outline,
      };

  Color _colorFor(PeerStatus status, ThemeData theme) => switch (status) {
        PeerStatus.online => Colors.green,
        PeerStatus.connecting => theme.colorScheme.primary,
        PeerStatus.offline => theme.colorScheme.onSurfaceVariant,
        PeerStatus.error => theme.colorScheme.error,
      };

  Future<void> _confirmRevoke(BuildContext context) async {
    final ok = await confirm(
      context,
      title: "Revoke device?",
      message: "Unpair from ${peer.name}? They will keep this device until "
          "someone revokes there too.",
      confirmLabel: "Revoke",
      destructive: true,
    );
    if (ok) await onRevoke();
  }
}

/// The buttons that start a pairing, plus the paste-a-code field. The two
/// pairing flows push their own pages; nothing renders inline here. Drawn only
/// while no pairing is in flight — the parent swaps in `_PairingStatus` once
/// one is.
class _PairingControls extends ConsumerStatefulWidget {
  const _PairingControls({required this.hub});

  final SyncHub hub;

  @override
  ConsumerState<_PairingControls> createState() => _PairingControlsState();
}

class _PairingControlsState extends ConsumerState<_PairingControls> {
  final _joinController = TextEditingController();

  @override
  void dispose() {
    _joinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Pair a new device",
          description: kIsWeb
              ? "A browser can only join: paste a code from another device, "
                  "or set a relay URL below and open a window over it."
              : "Open a window and show the code, or paste a code "
                  "from another device.",
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _openWindow,
                child: const Text("Open pairing window"),
              ),
              FilledButton.tonal(
                onPressed: _createInvite,
                child: const Text("Manual invite"),
              ),
            ],
          ),
        ),
        LabelledField(
          label: "Or paste a pairing code",
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _joinController,
                  decoration: const InputDecoration(
                    hintText: "entoli-pair:…",
                    isDense: true,
                  ),
                  onFieldSubmitted: (_) => _join(),
                ),
              ),
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: "Scan QR code",
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _scan,
                ),
              ],
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _join,
                child: const Text("Pair"),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openWindow() async {
    try {
      await widget.hub.startPairingWindow();
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PairingWindowPage(hub: widget.hub),
        ));
      }
    } catch (e) {
      if (mounted) say(context, e);
    }
  }

  Future<void> _createInvite() async {
    try {
      final blob = await widget.hub.createManualInvite();
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ManualInvitePage(hub: widget.hub, offer: blob),
        ));
      }
    } catch (e) {
      if (mounted) say(context, e);
    }
  }

  Future<void> _join() async {
    final text = _joinController.text.trim();
    if (text.isEmpty) return;
    try {
      // A manual invite's answer comes back as a non-null reply; `pairWith`
      // completes the pair from this end, and the activity notifier swaps the
      // status view in — no acknowledgment of our own is needed.
      await widget.hub.pairWith(text);
    } catch (e) {
      if (mounted) say(context, e);
    }
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanQrPage()),
    );
    if (scanned != null && scanned.isNotEmpty) {
      _joinController.text = scanned;
      _join();
    }
  }
}

/// The non-page status: a pairing the joiner started by pasting a code (LAN or
/// relay) shows its SAS confirm inline, since the joiner did not open a window
/// page. The window host's pairing is shown on the window page itself.
class _PairingStatus extends StatelessWidget {
  const _PairingStatus({required this.pairing, required this.hub});

  final PairingActivity pairing;
  final SyncHub hub;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          switch (pairing.stage) {
            PairingStage.connecting => const Text("Waiting for a device…"),
            PairingStage.confirming => _SasConfirm(pairing: pairing, hub: hub),
            PairingStage.done => const Text("Paired."),
            PairingStage.failed => _pairingFailed(context, pairing.error),
          },
          if (pairing.stage != PairingStage.done &&
              pairing.stage != PairingStage.confirming)
            TextButton(
              onPressed: hub.cancelPairingWindow,
              child: const Text("Cancel"),
            ),
        ],
      ),
    );
  }
}

/// The host's pairing window, as its own page: a QR and the selectable code,
/// and the SAS confirm once a device connects. Going back cancels the window.
class PairingWindowPage extends StatelessWidget {
  const PairingWindowPage({super.key, required this.hub});

  final SyncHub hub;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back cancels: leaving the page is giving up on the window, and an open
      // window left behind would hold a server and a relay room for nobody.
      // `onPopInvokedWithResult` runs before dispose, when the tree is not
      // locked, so the notifier's listeners can hear the cancel.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        hub.cancelPairingWindow();
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text("Pairing window")),
        body: ValueListenableBuilder<PairingActivity?>(
          valueListenable: hub.pairing,
          builder: (context, pairing, _) {
            if (pairing == null) {
              return const Center(child: Text("Pairing cancelled."));
            }
            return switch (pairing.stage) {
              PairingStage.confirming =>
                _SasConfirm(pairing: pairing, hub: hub),
              PairingStage.done => const Center(child: Text("Paired.")),
              PairingStage.failed => _pairingFailed(context, pairing.error),
              PairingStage.connecting => _PairingCodeBody(activity: pairing),
            };
          },
        ),
      ),
    );
  }
}

class _PairingCodeBody extends StatelessWidget {
  const _PairingCodeBody({required this.activity});

  final PairingActivity activity;

  @override
  Widget build(BuildContext context) {
    final code = activity.qr;
    if (code == null) {
      return const Center(child: Text("Waiting for a route…"));
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          "Show this code to the other device, or have it scan the QR. "
          "Going back cancels.",
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: QrImageView(
            data: code,
            size: 280,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        _CodeBox(context, code),
        const SizedBox(height: 12),
        Center(
          child: TextButton.icon(
            icon: const Icon(Icons.copy_outlined),
            label: const Text("Copy code"),
            onPressed: () => copyToClipboard(context, code,
                said: "Pairing code copied"),
          ),
        ),
        if (activity.code != null) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              "One-time code: ${activity.code}",
              style: const TextStyle(fontFamily: "monospace", fontSize: 16,
                  letterSpacing: 2),
            ),
          ),
        ],
      ],
    );
  }
}

/// Manual invite's own page: the offer blob is too large for a reliable QR
/// (it carries a full SDP offer), so it is selectable text only. The invited
/// device pastes our offer on its end, answers, and pastes the reply back here.
/// Going back cancels the pending invite.
class ManualInvitePage extends StatefulWidget {
  const ManualInvitePage({super.key, required this.hub, required this.offer});

  final SyncHub hub;
  final String offer;

  @override
  State<ManualInvitePage> createState() => _ManualInvitePageState();
}

class _ManualInvitePageState extends State<ManualInvitePage> {
  final _replyController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back cancels: `cancelPairingWindow` drops the pending manual invite so
      // the held peer connection is not left open for nobody. Done here rather
      // than in `dispose` so the notifier's listeners hear it before the tree
      // locks.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        widget.hub.cancelManualInvite();
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text("Manual invite")),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              "Manual invite works without a relay or local network. Send this "
              "code to the other device any way you like; it replies with a "
              "second code you paste back here. Going back cancels.",
            ),
            const SizedBox(height: 16),
            _CodeBox(context, widget.offer),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.copy_outlined),
                label: const Text("Copy invite"),
                onPressed: () => copyToClipboard(context, widget.offer,
                    said: "Invite code copied"),
              ),
            ),
            const SizedBox(height: 24),
            const Text("Paste the other device's reply here:"),
            const SizedBox(height: 8),
            TextField(
              controller: _replyController,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: "entoli-pair:…",
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _complete,
              child: const Text("Pair"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _complete() async {
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.hub.pairWith(text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) say(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The bordered monospace block a pairing code or manual invite is shown in,
/// selectable so it can be copied by hand. Used by the window page and the
/// manual invite page, which were two copies of the same container.
// ignore: non_constant_identifier_names
Widget _CodeBox(BuildContext context, String text) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: "monospace", fontSize: 11),
      ),
    );

/// The failure row, selectable so the error can be copied into an issue.
/// Drawn by both the window page and the inline status, so the styling lives
/// once rather than twice.
Widget _pairingFailed(BuildContext context, String? error) => Padding(
      padding: const EdgeInsets.all(24),
      child: SelectableText(
        "Failed: ${error ?? "unknown"}",
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );

/// The camera scanner for a pairing code, Android-only by the button that
/// opens it. Pops with the scanned text on a successful detect.
class _ScanQrPage extends StatefulWidget {
  const _ScanQrPage();

  @override
  State<_ScanQrPage> createState() => _ScanQrPageState();
}

class _ScanQrPageState extends State<_ScanQrPage> {
  final _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan QR code")),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_done) return;
          for (final barcode in capture.barcodes) {
            final value = barcode.displayValue ?? barcode.rawValue;
            if (value != null && value.isNotEmpty) {
              _done = true;
              _controller.stop();
              Navigator.of(context).pop(value);
              return;
            }
          }
        },
      ),
    );
  }
}

class _SasConfirm extends StatelessWidget {
  const _SasConfirm({required this.pairing, required this.hub});

  final PairingActivity pairing;
  final SyncHub hub;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Confirm the codes match on both devices:"),
        const SizedBox(height: 8),
        Center(
          child: Text(
            pairing.sas ?? "",
            style: const TextStyle(fontFamily: "monospace", fontSize: 24,
                letterSpacing: 4),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton(
              onPressed: () => hub.confirmPairing(true),
              child: const Text("Match"),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => hub.confirmPairing(false),
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text("Don't match"),
            ),
          ],
        ),
      ],
    );
  }
}
