import "dart:async";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/sync/sync_hub.dart";
import "../../domain/app_settings.dart";
import "../../domain/sync/devices.dart";
import "../../providers.dart";
import "../widgets/busy.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";

/// The Sync category: this device's identity and name, the relay and TURN
/// settings for reaching peers over the internet, and the list of paired
/// devices. Shown on every platform — a browser pairs as the joiner side, so
/// the identity and the paired-device list are still its business.
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
            isDefault: settings.deviceName == null,
            onReset: () =>
                ref.read(appSettingsProvider.notifier).setDeviceName(null),
            child: TextFormField(
              initialValue: settings.deviceName ?? "",
              decoration: const InputDecoration(
                hintText: "Entoli",
                isDense: true,
              ),
              onChanged: (value) => ref
                  .read(appSettingsProvider.notifier)
                  .setDeviceName(value.isEmpty ? null : value),
            ),
          ),
        ),
        Divider(),
        _RelaySection(settings: settings),
        Divider(),
        _TurnSection(settings: settings),
        Divider(),
        _PairedDevices(hub: hub),
        Divider(),
        ValueListenableBuilder(
          valueListenable: hub.pairing,
          builder: (context, pairing, _) =>
              _PairingControls(hub: hub, pairing: pairing),
        ),
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
                .setTurnCredentials(
                    value.isEmpty ? null : value, settings.turnPassword),
          ),
        ),
        LabelledField(
          label: "TURN password",
          child: TextFormField(
            initialValue: settings.turnPassword ?? "",
            obscureText: true,
            decoration: const InputDecoration(isDense: true),
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setTurnCredentials(settings.turnUsername,
                    value.isEmpty ? null : value),
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
    final registry = ref.watch(deviceRegistryProvider);
    return FutureBuilder(
      future: registry.list(),
      builder: (context, snapshot) {
        final devices = snapshot.data ?? const [];
        return ValueListenableBuilder(
          valueListenable: hub.peers,
          builder: (context, peers, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                "Paired devices",
                description: devices.isEmpty
                    ? "No devices paired yet. Open a pairing window below and "
                        "scan the code from another device."
                    : null,
              ),
              for (final device in devices)
                _PairedDeviceRow(
                  device: device,
                  state: peers[device.id],
                  onRevoke: () async {
                    await hub.revoke(device.id);
                    ref.invalidate(deviceRegistryProvider);
                  },
                  onConnect: () => hub.connect(device.id),
                  onDisconnect: () => hub.disconnect(device.id),
                  onFailed: (error) => _say(context, error),
                ),
            ],
          ),
        );
      },
    );
  }
}

void _say(BuildContext context, Object error) => ScaffoldMessenger.of(context)
    .showSnackBar(SnackBar(content: Text(error.toString())));

class _PairedDeviceRow extends StatelessWidget {
  const _PairedDeviceRow({
    required this.device,
    required this.state,
    required this.onRevoke,
    required this.onConnect,
    required this.onDisconnect,
    required this.onFailed,
  });

  final PairedDevice device;
  final PeerState? state;
  final Future<void> Function() onRevoke;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  /// A dial that could not find the device. Reported here rather than left to
  /// the future nobody awaits: `onPressed` takes a `VoidCallback`, so an
  /// unawaited failure is an unhandled error and a button that did nothing.
  final void Function(Object error) onFailed;

  @override
  Widget build(BuildContext context) {
    final status = state?.status ?? PeerStatus.offline;
    final theme = Theme.of(context);
    final failure = state?.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(status), size: 16, color: _colorFor(status, theme)),
              const SizedBox(width: 8),
              Expanded(child: Text(device.name)),
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
      message: "Unpair from ${device.name}? They will keep this device until "
          "someone revokes there too.",
      confirmLabel: "Revoke",
      destructive: true,
    );
    if (ok) await onRevoke();
  }
}

class _PairingControls extends ConsumerStatefulWidget {
  const _PairingControls({required this.hub, required this.pairing});

  final SyncHub hub;
  final PairingActivity? pairing;

  @override
  ConsumerState<_PairingControls> createState() => _PairingControlsState();
}

class _PairingControlsState extends ConsumerState<_PairingControls> {
  final _joinController = TextEditingController();
  final _busy = ValueNotifier(false);

  @override
  void dispose() {
    _joinController.dispose();
    _busy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pairing = widget.pairing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          "Pair a new device",
          description: kIsWeb
              ? "A browser can only join: paste a code from another device, "
                  "or set a relay URL above and open a window over it."
              : "Open a window and show the code, or paste a code "
                  "from another device.",
        ),
        if (pairing == null) ...[
          ValueListenableBuilder<bool>(
            valueListenable: _busy,
            builder: (context, busy, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      FilledButton(
                        onPressed: busy ? null : _openWindow,
                        child: const Text("Open pairing window"),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: busy ? null : _createInvite,
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
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: busy ? null : _join,
                        child: const Text("Pair"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          _PairingProgress(pairing: pairing, hub: widget.hub),
        ],
      ],
    );
  }

  Future<void> _openWindow() =>
      whileBusy(context, _busy, widget.hub.startPairingWindow);

  Future<void> _createInvite() => whileBusy(context, _busy, () async {
        final blob = await widget.hub.createManualInvite();
        if (mounted) await _showBlob(context, blob);
      });

  Future<void> _join() {
    final text = _joinController.text.trim();
    if (text.isEmpty) return Future.value();
    return whileBusy(context, _busy, () async {
      final reply = await widget.hub.pairWith(text);
      if (reply != null && mounted) {
        await _showBlob(context, reply, isAnswer: true);
      }
    });
  }

  Future<void> _showBlob(BuildContext context, String blob,
      {bool isAnswer = false}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isAnswer ? "Paste this on the other device" : "Pairing invite"),
        content: SingleChildScrollView(
          child: SelectableText(
            blob,
            style: const TextStyle(fontFamily: "monospace", fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              copyToClipboard(context, blob, said: "Pairing code copied");
              Navigator.pop(context);
            },
            child: const Text("Copy and close"),
          ),
        ],
      ),
    );
  }
}

class _PairingProgress extends ConsumerWidget {
  const _PairingProgress({required this.pairing, required this.hub});

  final PairingActivity pairing;
  final SyncHub hub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          switch (pairing.stage) {
            PairingStage.connecting => const Text("Waiting for a device…"),
            PairingStage.confirming => _SasConfirm(pairing: pairing, hub: hub),
            PairingStage.done => const Text("Paired."),
            PairingStage.failed => Text("Failed: ${pairing.error ?? "unknown"}",
                style: TextStyle(color: theme.colorScheme.error)),
          },
          if (pairing.qr != null && pairing.stage == PairingStage.connecting) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
              ),
              child: SelectableText(
                pairing.qr!,
                style: const TextStyle(fontFamily: "monospace", fontSize: 11),
              ),
            ),
          ],
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
