import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/settings/keys.dart";
import "package:entoli_core/model/settings/setting.dart";
import "package:entoli_core/view/widgets/dialogs.dart";
import "package:entoli_core/view/widgets/page_bar.dart";

import "../../app/settings/pairing.dart";
import "../../core/platform/form_factor.dart";
import "../../data/sync/sync_hub.dart";
import "../../providers.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "paired_device_page.dart";
import "sync_pairing.dart";

/// The Sync category: this device's name, then how to pair a new device, the
/// paired-device list, and the relay and TURN rows for reaching peers over
/// the internet.
class SyncSettings extends ConsumerWidget {
  const SyncSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final hub = ref.watch(syncHubProvider);
    return ListView(
      children: [
        SectionHeader(
          "Sync",
          description:
              "Pair with another device to mirror chats and take "
              "remote control. Chats stay on their home device; a mirror is "
              "RAM-only and never written to disk.",
        ),
        // The name the other device would file this one under with nothing
        // typed here, rather than a stand-in for it.
        LabelledField(
          label: "Device name",
          child: _SettingText(
            SettingKeys.deviceName,
            hint: hub.defaultDeviceName,
            resettable: true,
          ),
        ),
        const Divider(),
        // Always here: a pairing in flight is its own screen, so pairing
        // another device is always one button away.
        SectionHeader(
          "Pair a new device",
          description:
              "Open a window and show the code, or paste a code "
              "from another device.",
        ),
        PairingControls(flow: ref.watch(pairingFlowProvider)),
        const Divider(),
        _PairedDevices(hub: hub),
        // The phones freeze the process with the screen, so only they have a
        // keep-alive to switch.
        if (isPhone) ...[
          const Divider(),
          SwitchListTile(
            title: const Text("Keep connected off screen"),
            subtitle: Text(
              isAndroid
                  ? "While a device is connected, hold the app open off "
                        "screen with a notification naming it and a "
                        "Disconnect action. Costs battery — a wake lock for "
                        "as long as the connection lasts."
                  : "While a device is connected, keep the app running off "
                        "screen with a Live Activity naming it. Stopping the "
                        "activity disconnects. Costs battery for as long as "
                        "the connection lasts.",
            ),
            value: settings.syncKeepAlive,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .put(SettingKeys.syncKeepAlive, value),
          ),
        ],
        const Divider(),
        ListTile(
          title: const Text("Internet relay"),
          subtitle: Text(settings.syncRelayUrl ?? "Not set"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const RelaySettingsPage())),
        ),
        ListTile(
          title: const Text("TURN server"),
          subtitle: Text(settings.turnUrl ?? "Not set"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const TurnSettingsPage())),
        ),
      ],
    );
  }
}

/// An app-level text setting, unset where it is empty.
class _SettingText extends ConsumerStatefulWidget {
  const _SettingText(this.setting, {this.hint, this.resettable = false});

  final Setting<String> setting;
  final String? hint;
  final bool resettable;

  @override
  ConsumerState<_SettingText> createState() => _SettingTextState();
}

class _SettingTextState extends ConsumerState<_SettingText> {
  late final _text = TextEditingController(
    text: ref.read(appSettingsProvider).doc.read(widget.setting) ?? "",
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _write(String value) => ref
      .read(appSettingsProvider.notifier)
      .put(widget.setting, value.isEmpty ? null : value);

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: _text,
      decoration: InputDecoration(hintText: widget.hint, isDense: true),
      onChanged: _write,
    );
    if (!widget.resettable) return field;
    return ResettableField(
      onReset: () {
        _text.clear();
        _write("");
      },
      child: field,
    );
  }
}

/// The Internet relay: the `wss://` URL both devices dial to pair across the
/// internet, where the local network cannot reach them.
class RelaySettingsPage extends StatelessWidget {
  const RelaySettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: PageBar(title: "Internet relay"),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: mutedParagraph(
            context,
            "A WebSocket relay for pairing when the devices are not on "
            "the same network. Both dial the same room, derived from the "
            "pairing secret, so the relay sees nothing readable.",
          ),
        ),
        const LabelledField(
          label: "Relay URL",
          child: _SettingText(
            SettingKeys.syncRelayUrl,
            hint: "wss://relay.example.com",
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: mutedParagraph(
            context,
            "Any relay that speaks the room protocol works; "
            "tool/sync/sync_relay_server.dart is a reference one. Leave "
            "empty when the devices meet over the local network or "
            "manual paste.",
          ),
        ),
      ],
    ),
  );
}

/// The TURN server, only about NAT traversal: pairing needs nothing here
/// when a direct connection works.
class TurnSettingsPage extends ConsumerWidget {
  const TurnSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secrets = ref.watch(appSecretsProvider);
    return Scaffold(
      appBar: PageBar(title: "TURN server"),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: mutedParagraph(
              context,
              "For NAT traversal. Bring your own, a self-hosted coturn is "
              "recommended. Without one, symmetric-NAT pairs fail "
              "honestly.",
            ),
          ),
          const LabelledField(
            label: "TURN URL",
            child: _SettingText(
              SettingKeys.turnUrl,
              hint: "turn:turn.example.com:3478",
            ),
          ),
          const LabelledField(
            label: "TURN username",
            child: _SettingText(SettingKeys.turnUsername),
          ),
          LabelledField(
            label: "TURN password",
            // In the secret store, not settings, so it does not ride a
            // backup.
            child: TextFormField(
              initialValue: secrets.turnPassword ?? "",
              obscureText: true,
              decoration: const InputDecoration(isDense: true),
              onChanged: (value) =>
                  secrets.setTurnPassword(value.isEmpty ? null : value),
            ),
          ),
        ],
      ),
    );
  }
}

class _PairedDevices extends ConsumerWidget {
  const _PairedDevices({required this.hub});

  final SyncHub hub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One source for both membership and status, so a device paired while
    // the page is open appears on it.
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
        for (final peer in peers) _PairedDeviceRow(hub: hub, peer: peer),
      ],
    );
  }
}

class _PairedDeviceRow extends StatelessWidget {
  const _PairedDeviceRow({required this.hub, required this.peer});

  final SyncHub hub;
  final PeerState peer;

  @override
  Widget build(BuildContext context) {
    final status = peer.status;
    final theme = Theme.of(context);
    final failure = peer.error;
    void tried(Future<void> Function() work) => catchAndSay(context, work);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PairedDevicePage(deviceId: peer.deviceId),
          ),
        ),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  peerStatusIcon(status),
                  size: 16,
                  color: peerStatusColor(status, theme),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(peer.name)),
                if (status == PeerStatus.online)
                  TextButton(
                    onPressed: () => tried(() => hub.disconnect(peer.deviceId)),
                    child: const Text("Disconnect"),
                  )
                else
                  TextButton(
                    onPressed: status == PeerStatus.connecting
                        ? null
                        : () => tried(() => hub.connect(peer.deviceId)),
                    child: const Text("Connect"),
                  ),
                TextButton(
                  onPressed: () => confirmRevokeDevice(
                    context,
                    peer.name,
                    () => hub.revoke(peer.deviceId),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  child: const Text("Revoke"),
                ),
              ],
            ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 8),
                child: SelectableText(
                  failure,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
