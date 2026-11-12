import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/platform/form_factor.dart";
import "../../../data/sync/peers.dart";
import "../../../data/sync/sync_hub.dart" show SyncHub;
import "../../../domain/settings/keys.dart";
import "../../../domain/settings/setting.dart";
import "../../../providers.dart";
import "../bind.dart";
import "../controller.dart";
import "../hand_off.dart";
import "../pairing.dart";
import "../spec.dart";

const _page = SettingsPageId.sync;

/// The pairing in flight, as it changes.
final pairingActivityProvider =
    NotifierProvider<PairingWatch, PairingActivity?>(PairingWatch.new);

class PairingWatch extends HubValue<PairingActivity?> {
  @override
  ValueListenable<PairingActivity?> of(SyncHub hub) => hub.pairing;
}

final syncSections = [
  const SectionSpec(
    page: _page,
    id: "sync",
    title: "Sync",
    weight: 0,
    description:
        "Pair with another device to mirror chats and take "
        "remote control. Chats stay on their home device; a mirror is "
        "RAM-only and never written to disk.",
  ),
  // Always here: a pairing in flight is its own screen and these controls
  // stay where they were, pairing another device always one button away.
  const SectionSpec(
    page: _page,
    id: "pair",
    title: "Pair a new device",
    weight: 10,
    description:
        "Open a window and show the code, or paste a code "
        "from another device.",
  ),
  SectionSpec(
    page: _page,
    id: "paired",
    title: "Paired devices",
    weight: 20,
    keepEmpty: true,
    describe: (ref) => ref.watch(syncPeersProvider).isEmpty
        ? "No devices paired yet. Pair a new device above."
        : null,
  ),
  // Where the keep-alive's foreground service exists: Android, the one
  // platform whose process freezes with the screen.
  SectionSpec(
    page: _page,
    id: "keepAlive",
    title: "",
    weight: 30,
    shown: (_) => isAndroid,
  ),
  const SectionSpec(page: _page, id: "reach", title: "", weight: 40),
  const SectionSpec(
    page: SettingsPageId.syncRelay,
    id: "relay",
    title: "",
    weight: 0,
  ),
  const SectionSpec(
    page: SettingsPageId.syncTurn,
    id: "turn",
    title: "",
    weight: 0,
  ),
];

/// Text over a key at the app's level, unset where it is empty.
TextController _text(
  SettingContext c,
  Setting<String> key, {
  String? prompt,
  String? clearLabel,
  String? footnote,
}) => TextController(
  c.spec,
  value: c.scope.resolve(key) ?? "",
  prompt: prompt,
  clearLabel: clearLabel,
  footnote: footnote,
  onSet: (text) async {
    await c.scope.write(key, text.isEmpty ? null : text);
    return null;
  },
);

SettingGlyph _statusGlyph(PeerStatus status) => switch (status) {
  PeerStatus.online => SettingGlyph.online,
  PeerStatus.connecting => SettingGlyph.connecting,
  PeerStatus.offline => SettingGlyph.offline,
  PeerStatus.error => SettingGlyph.failed,
};

final syncSettings = [
  SettingSpec(
    id: "deviceName",
    path: (page: _page, section: "sync"),
    weight: 0,
    title: "Device name",
    hint: UiHint.input,
    // The name the other device would file this one under with nothing
    // typed here, rather than a stand-in for it.
    build: (c) => _text(
      c,
      SettingKeys.deviceName,
      prompt: c.ref.watch(syncHubProvider).defaultDeviceName,
      clearLabel: "the default name",
    ),
  ),
  SettingSpec(
    id: "pairing",
    path: (page: _page, section: "pair"),
    weight: 0,
    title: "Pair a new device",
    hint: UiHint.row,
    build: (c) {
      final scanner = c.ref.read(settingsHandOffProvider).scanCode;
      return PairingController(
        c.spec,
        flow: c.ref.watch(pairingFlowProvider),
        activity: c.ref.watch(pairingActivityProvider),
        scanner: isPhone ? scanner : null,
      );
    },
  ),
  SettingSpec(
    id: "pairedDevices",
    path: (page: _page, section: "paired"),
    weight: 0,
    title: "Paired devices",
    hint: UiHint.row,
    build: (c) {
      // One source for both membership and status, so a device paired while
      // the page is open appears on it.
      final peers = c.ref.watch(syncPeersProvider).values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final hub = c.ref.read(syncHubProvider);
      final handOff = c.ref.read(settingsHandOffProvider);
      return CollectionController<PeerState>(
        c.spec,
        items: peers,
        addLabel: "Pair a new device",
        removable: false,
        visible: peers.isNotEmpty,
        describe: (peer) => CollectionItem(
          peer.name,
          id: peer.deviceId,
          tap: handOff.pairedDevice == null ? null : "open",
          error: peer.error,
          glyph: _statusGlyph(peer.status),
          tone: switch (peer.status) {
            PeerStatus.online => NoticeTone.good,
            PeerStatus.error => NoticeTone.warning,
            _ => NoticeTone.plain,
          },
          actions: [
            if (handOff.pairedDevice != null)
              ItemAction(
                "open",
                "Details…",
                handsOff: !handOff.pairedDeviceInSettings,
              ),
            if (peer.status == PeerStatus.online)
              const ItemAction("disconnect", "Disconnect")
            else
              ItemAction(
                "connect",
                "Connect",
                enabled: peer.status != PeerStatus.connecting,
              ),
            ItemAction(
              "revoke",
              "Revoke",
              destructive: true,
              confirm: SettingConfirm(
                title: "Revoke device?",
                message:
                    "Unpair from ${peer.name}? They will keep this device "
                    "until someone revokes there too.",
                confirmLabel: "Revoke",
                destructive: true,
              ),
            ),
          ],
        ),
        onSet: (_) async {},
        act: (index, action) async {
          final id = peers[index].deviceId;
          try {
            await switch (action) {
              "open" => handOff.pairedDevice!(id),
              "connect" => hub.connect(id),
              "disconnect" => hub.disconnect(id),
              _ => hub.revoke(id),
            };
            return null;
          } catch (e) {
            return SettingNotice("$e");
          }
        },
      );
    },
  ),
  SettingSpec(
    id: "syncKeepAlive",
    path: (page: _page, section: "keepAlive"),
    weight: 0,
    title: "Keep connected off screen",
    description:
        "While a device is connected, hold the app open off screen with a "
        "notification naming it and a Disconnect action. Costs battery — "
        "a wake lock for as long as the connection lasts.",
    hint: UiHint.toggle,
    build: (c) => c.toggle(SettingKeys.syncKeepAlive),
  ),
  SettingSpec(
    id: "syncRelay",
    path: (page: _page, section: "reach"),
    weight: 0,
    title: "Internet relay",
    hint: UiHint.row,
    build: (c) => SubpageController(
      c.spec,
      page: SettingsPageId.syncRelay,
      summary: c.scope.resolve(SettingKeys.syncRelayUrl) ?? "Not set",
    ),
  ),
  SettingSpec(
    id: "syncTurn",
    path: (page: _page, section: "reach"),
    weight: 10,
    title: "TURN server",
    hint: UiHint.row,
    build: (c) => SubpageController(
      c.spec,
      page: SettingsPageId.syncTurn,
      summary: c.scope.resolve(SettingKeys.turnUrl) ?? "Not set",
    ),
  ),
  // The relay both devices dial to pair across the internet, where the
  // local network cannot reach them.
  SettingSpec(
    id: "syncRelayAbout",
    path: (page: SettingsPageId.syncRelay, section: "relay"),
    weight: 0,
    title: "Internet relay",
    hint: UiHint.paragraph,
    build: (c) => NoticeController(
      c.spec,
      lines: const [
        NoticeLine(
          "A WebSocket relay for pairing when the devices are not on "
          "the same network. Both dial the same room, derived from the "
          "pairing secret, so the relay sees nothing readable.",
        ),
      ],
    ),
  ),
  SettingSpec(
    id: "syncRelayUrl",
    path: (page: SettingsPageId.syncRelay, section: "relay"),
    weight: 10,
    title: "Relay URL",
    hint: UiHint.input,
    build: (c) => _text(
      c,
      SettingKeys.syncRelayUrl,
      prompt: "wss://relay.example.com",
      footnote:
          "Any relay that speaks the room protocol works; "
          "tool/sync/sync_relay_server.dart is a reference one. Leave "
          "empty when the devices meet over the local network or "
          "manual paste.",
    ),
  ),
  // Only about NAT traversal: pairing needs nothing here when a direct
  // connection works.
  SettingSpec(
    id: "syncTurnAbout",
    path: (page: SettingsPageId.syncTurn, section: "turn"),
    weight: 0,
    title: "TURN server",
    hint: UiHint.paragraph,
    build: (c) => NoticeController(
      c.spec,
      lines: const [
        NoticeLine(
          "For NAT traversal. Bring your own, a self-hosted coturn is "
          "recommended. Without one, symmetric-NAT pairs fail "
          "honestly.",
        ),
      ],
    ),
  ),
  SettingSpec(
    id: "turnUrl",
    path: (page: SettingsPageId.syncTurn, section: "turn"),
    weight: 10,
    title: "TURN URL",
    hint: UiHint.input,
    build: (c) =>
        _text(c, SettingKeys.turnUrl, prompt: "turn:turn.example.com:3478"),
  ),
  SettingSpec(
    id: "turnUsername",
    path: (page: SettingsPageId.syncTurn, section: "turn"),
    weight: 20,
    title: "TURN username",
    hint: UiHint.input,
    build: (c) => _text(c, SettingKeys.turnUsername),
  ),
  // Held in the secret store, not settings, so it does not ride a backup.
  SettingSpec(
    id: "turnPassword",
    path: (page: SettingsPageId.syncTurn, section: "turn"),
    weight: 30,
    title: "TURN password",
    hint: UiHint.input,
    build: (c) {
      final secrets = c.ref.watch(appSecretsProvider);
      return TextController(
        c.spec,
        value: secrets.turnPassword ?? "",
        secret: true,
        onSet: (text) async {
          await secrets.setTurnPassword(text.isEmpty ? null : text);
          return null;
        },
      );
    },
  ),
];
