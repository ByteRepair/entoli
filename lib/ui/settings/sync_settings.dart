import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:mobile_scanner/mobile_scanner.dart";
import "package:qr_flutter/qr_flutter.dart";
import "package:url_launcher/url_launcher.dart";

import "../../core/log.dart";
import "../../core/platform/form_factor.dart";
import "../../data/sync/sync_hub.dart";
import "../../domain/app_settings.dart";
import "../../providers.dart";
import "../widgets/dialogs.dart";
import "../widgets/resettable_field.dart";
import "../widgets/section_header.dart";
import "paired_device_page.dart";

/// The Sync category: this device's name, then how to pair a new device, the
/// paired-device list, and the relay and TURN rows for reaching peers over
/// the internet. Shown on every platform — a browser pairs as the joiner
/// side, so the name and the paired-device list are still its business.
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
        // Always here: a pairing in flight is its own screen and this page's
        // controls stay where they were. Nothing about a pairing hides them —
        // pairing another device is always one button away.
        _PairingControls(hub: hub),
        Divider(),
        _PairedDevices(hub: hub),
        if (_android) ...[Divider(), _KeepAliveField(settings: settings)],
        Divider(),
        ListTile(
          title: const Text("Internet relay"),
          subtitle: Text(settings.syncRelayUrl ?? "Not set"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RelaySettingsPage())),
        ),
        ListTile(
          title: const Text("TURN server"),
          subtitle: Text(settings.turnUrl ?? "Not set"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TurnSettingsPage())),
        ),
      ],
    );
  }
}

/// Where the sync keep-alive's foreground service exists: Android only, the
/// one platform whose process freezes with the screen. Everywhere else the
/// setting has nothing to switch, so the row is not drawn.
bool get _android => isAndroid;

/// Where the paste-a-code field gets a camera button: the phones, the devices
/// that are pointed at a code another screen shows.
bool get _canScan => isPhone;

/// The Internet relay, on its own screen — reached from the row on the Sync
/// page. One field: the `wss://` URL both devices dial to pair across the
/// internet, where the local network cannot reach them.
class RelaySettingsPage extends ConsumerWidget {
  const RelaySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text("Internet relay")),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: mutedParagraph(
                context,
                "A WebSocket relay for pairing when the devices are not on "
                "the same network. Both dial the same room, derived from the "
                "pairing secret, so the relay sees nothing readable."),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: mutedParagraph(
                context,
                "Any relay that speaks the room protocol works; "
                "tool/sync/sync_relay_server.dart is a reference one. Leave "
                "empty when the devices meet over the local network or "
                "manual paste."),
          ),
        ],
      ),
    );
  }
}

/// The TURN server, on its own screen — reached from the row on the Sync
/// page, and only about NAT traversal: pairing needs nothing here when a
/// direct connection works. The password is held in the secret store.
class TurnSettingsPage extends ConsumerWidget {
  const TurnSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final secrets = ref.watch(appSecretsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text("TURN server")),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: mutedParagraph(
                context,
                "For NAT traversal. Bring your own, a self-hosted coturn is "
                "recommended. Without one, symmetric-NAT pairs fail "
                "honestly."),
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
              // Held in the secret store, not settings, so it does not ride
              // a backup — read through the mirror here the way every other
              // field reads its own value.
              initialValue: secrets.turnPassword ?? "",
              obscureText: true,
              decoration: const InputDecoration(isDense: true),
              onChanged: (value) => secrets
                  .setTurnPassword(value.isEmpty ? null : value),
            ),
          ),
        ],
      ),
    );
  }
}

/// Android-only — the parent draws this row nowhere else, since the setting
/// has nothing to answer for on a platform whose process survives the screen.
class _KeepAliveField extends ConsumerWidget {
  const _KeepAliveField({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile(
      title: const Text("Keep connected off screen"),
      subtitle: const Text(
        "While a device is connected, hold the app open off screen with a "
        "notification naming it and a Disconnect action. Costs battery — "
        "a wake lock for as long as the connection lasts.",
      ),
      value: settings.syncKeepAlive,
      onChanged: (value) =>
          ref.read(appSettingsProvider.notifier).setSyncKeepAlive(value),
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
    void tried(Future<void> Function() work) =>
        catchAndSay(context, work);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        // The row is the device's page's way in: clicking it anywhere that
        // is not a button opens the device's own screen.
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PairedDevicePage(deviceId: peer.deviceId),
        )),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(peerStatusIcon(status),
                    size: 16, color: peerStatusColor(status, theme)),
                const SizedBox(width: 8),
                Expanded(child: Text(peer.name)),
                if (status == PeerStatus.online)
                  TextButton(
                      onPressed: () =>
                          tried(() => hub.disconnect(peer.deviceId)),
                      child: const Text("Disconnect"))
                else
                  TextButton(
                      onPressed: status == PeerStatus.connecting
                          ? null
                          : () => tried(() => hub.connect(peer.deviceId)),
                      child: const Text("Connect")),
                TextButton(
                  onPressed: () =>
                      confirmRevokeDevice(context, peer.name,
                          () => hub.revoke(peer.deviceId)),
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  child: const Text("Revoke"),
                ),
              ],
            ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 8),
                child: SelectableText(
                  failure,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The buttons that start a pairing, plus the paste-a-code field. Every
/// pairing goes to a screen of its own — the window's, the invite's, the
/// joiner's — where the wait, the codes and the end are shown. Nothing
/// renders inline here, and the section keeps these controls the whole time.
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
                  "or set a relay URL under Internet relay below and open a "
                  "window over it."
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
                onPressed: () =>
                    PairingWindowPage.openAnother(context, widget.hub),
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
              if (_canScan) ...[
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

  Future<void> _join([String? scanned]) async {
    final text = (scanned ?? _joinController.text).trim();
    if (text.isEmpty) return;
    // The pairing runs on its own screen: this push opens it, and the pairing
    // is started from there — it shows the wait, the codes and the paired or
    // failed end. Nothing here is hidden while any of it goes on.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PairingJoinPage(hub: widget.hub, code: text),
    ));
    _joinController.clear();
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanQrPage()),
    );
    if (mounted && scanned != null && scanned.isNotEmpty) _join(scanned);
  }
}

/// Back on a pairing screen is giving up: the route pops through this scope,
/// whose cancel runs before dispose — while the tree is unlocked, so the
/// activity notifier's listeners hear it — and then the pop completes. The
/// cancel verb is the screen's: the joiner's is `cancelPairing`, the window's
/// adds its teardown, the invite's drops the held link with it.
PopScope _cancelOnBack(BuildContext context, VoidCallback cancel,
        {required Widget child}) =>
    PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        cancel();
        Navigator.of(context).pop();
      },
      child: child,
    );

/// The joiner's own screen: pushed by Pair, for a pasted code or a scanned
/// one. A pairing this device did not open a window for still gets a screen —
/// the wait on it, then the codes, then paired or failed — and going back
/// answers a pending codes-matched gate "no", so the pair does not hang on a
/// human who has left.
class PairingJoinPage extends StatefulWidget {
  const PairingJoinPage({super.key, required this.hub, required this.code});

  final SyncHub hub;

  /// The code the joiner pasted or scanned; the pairing starts from here.
  final String code;

  @override
  State<PairingJoinPage> createState() => _PairingJoinPageState();
}

class _PairingJoinPageState extends State<PairingJoinPage> {
  @override
  void initState() {
    super.initState();
    // One frame in, so the activity the body watches is being watched first:
    // connecting is the wait this screen is pushed to show.
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  Future<void> _begin() async {
    try {
      await widget.hub.pairWith(widget.code);
    } catch (e) {
      // A throw with no pairing under it — usually a code that is not one —
      // has no failed arm to render: said here, and this screen leaves.
      // Otherwise `_fail` already moved the activity to failed.
      if (mounted && widget.hub.pairing.value == null) {
        say(context, e);
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    return _cancelOnBack(
      context,
      hub.cancelPairing,
      child: Scaffold(
        appBar: AppBar(title: const Text("Pairing")),
        body: _PairingStageView.watching(
            context, hub, "Waiting for the other device…"),
      ),
    );
  }
}

/// What a pairing shows once a device is on the other end, shared by every
/// pairing screen: the codes-matched confirm, then paired or failed. The arm
/// before those is the hosting page's own — the window's QR, a wait elsewhere.
class _PairingStageView extends StatelessWidget {
  const _PairingStageView({
    required this.hub,
    required this.activity,
    required this.connecting,
    required this.onPairAnother,
    required this.onDone,
  });

  final SyncHub hub;
  final PairingActivity activity;
  final Widget connecting;
  final VoidCallback onPairAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return switch (activity.stage) {
      PairingStage.connecting => connecting,
      PairingStage.confirming => Padding(
          padding: const EdgeInsets.all(24),
          child: _SasConfirm(pairing: activity, hub: hub),
        ),
      PairingStage.done => _PairedView(
          pairing: activity,
          onPairAnother: onPairAnother,
          onDone: onDone,
        ),
      PairingStage.failed => _pairingFailed(context, activity.error),
    };
  }

  /// The harness a pairing screen that is not the window's one shares: it
  /// shows a spinner before the activity arrives (the pairing is being
  /// opened), then the stages, with the contract all three pages state once
  /// here — "Pair another device" is a fresh window pushed over this screen,
  /// and Done cancels what is left of the pairing on the way back to the
  /// Sync page.
  static Widget watching(
      BuildContext context, SyncHub hub, String waitLabel) {
    return ValueListenableBuilder<PairingActivity?>(
      valueListenable: hub.pairing,
      builder: (context, pairing, _) {
        if (pairing == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return _PairingStageView(
          hub: hub,
          activity: pairing,
          connecting: _PairingWait(waitLabel),
          onPairAnother: () => PairingWindowPage.openAnother(context, hub),
          onDone: () {
            hub.cancelPairing();
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}

/// The wait where there is nothing to show but the wait. The joiner's and the
/// invite's connecting arms; the window's is the QR instead.
class _PairingWait extends StatelessWidget {
  const _PairingWait(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      );
}

/// The pairing-is-done screen: which device was just paired, and the two ways
/// on — pair another, or be done. "Device so-and-so has been paired." is the
/// headline; the bare "Paired." this once was made every pairing the last.
class _PairedView extends StatelessWidget {
  const _PairedView({
    required this.pairing,
    required this.onPairAnother,
    required this.onDone,
  });

  final PairingActivity pairing;
  final VoidCallback onPairAnother;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = pairing.peerName;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              (name == null || name.isEmpty)
                  ? "The device has been paired."
                  : "Device $name has been paired.",
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            mutedParagraph(
                context,
                "Either device can now dial the other without re-pairing, "
                "and it is listed under Paired devices.",
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonal(
                  onPressed: onPairAnother,
                  child: const Text("Pair another device"),
                ),
                TextButton(onPressed: onDone, child: const Text("Done")),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The host's pairing window, as its own page: a QR and the selectable code,
/// the SAS confirm once a device connects, and the paired screen once the
/// pair completes. Going back cancels the window.
class PairingWindowPage extends StatefulWidget {
  const PairingWindowPage({super.key, required this.hub});

  final SyncHub hub;

  /// "Pair another device" from any pairing screen that is not the window's
  /// one: a fresh window opens and its page pushes over the screen saying it.
  /// The window's own paired screen reopens in place instead.
  static Future<void> openAnother(BuildContext context, SyncHub hub) async {
    try {
      await hub.startPairingWindow();
      if (context.mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PairingWindowPage(hub: hub),
        ));
      }
    } catch (e) {
      if (context.mounted) say(context, e);
    }
  }

  @override
  State<PairingWindowPage> createState() => _PairingWindowPageState();
}

class _PairingWindowPageState extends State<PairingWindowPage> {
  /// A pairing the page itself just opened — "Pair another device" on the
  /// paired screen. Between `startPairingWindow`'s cancel of the finished
  /// one and its open of the fresh one there is a window with nothing in
  /// it; a spinner says that is happening rather than "Pairing cancelled."
  bool _busy = false;

  Future<void> _openWindow(BuildContext context) async {
    setState(() => _busy = true);
    try {
      await widget.hub.startPairingWindow();
    } catch (e) {
      if (context.mounted) say(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.hub;
    return _cancelOnBack(context, hub.cancelPairingWindow,
        child: Scaffold(
          appBar: AppBar(title: const Text("Pairing window")),
          body: ValueListenableBuilder<PairingActivity?>(
            valueListenable: hub.pairing,
            builder: (context, pairing, _) {
              if (pairing == null) {
                return _busy
                    ? const Center(child: CircularProgressIndicator())
                    : const Center(child: Text("Pairing cancelled."));
              }
              return _PairingStageView(
                hub: hub,
                activity: pairing,
                // The window's own connecting arm: the thing to do while
                // waiting is show the code.
                connecting: _PairingCodeBody(activity: pairing),
                // "Pair another" is a window again, on this page: the
                // activity notifier moves it back to the QR.
                onPairAnother: () => unawaited(_openWindow(context)),
                onDone: () {
                  hub.cancelPairingWindow();
                  Navigator.of(context).pop();
                },
              );
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

  /// Whether the reply has been handed over. Once it is, the body becomes the
  /// shared pairing stages — the wait, the codes, paired or failed — the same
  /// screen any other pairing ends on. It comes back only for a refusal with
  /// nothing started under it.
  bool _watching = false;

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // One verb: a pending invite loses its held link, and, once the reply is
    // in, the completing pair's gate is answered no. See
    // [SyncPairing.cancelManualInvite].
    return _cancelOnBack(
      context,
      widget.hub.cancelManualInvite,
      child: Scaffold(
        appBar: AppBar(title: const Text("Manual invite")),
        body: _watching ? _watchingBody() : _inviteBody(),
      ),
    );
  }

  Widget _inviteBody() {
    return ListView(
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
          onPressed: _complete,
          child: const Text("Pair"),
        ),
      ],
    );
  }

  /// The reply accepted: how the pairing goes is all that is left on this
  /// page, drawn by the same stages every pairing screen ends on.
  Widget _watchingBody() =>
      _PairingStageView.watching(context, widget.hub, "Completing the pairing…");

  Future<void> _complete() async {
    final text = _replyController.text.trim();
    if (text.isEmpty) return;
    setState(() => _watching = true);
    try {
      await widget.hub.pairWith(text);
    } catch (e) {
      // A refusal before any pairing existed — usually the reply for another
      // invite — has no failed arm to render. The form is back.
      // Otherwise `_fail` already moved the activity to failed.
      if (mounted && widget.hub.pairing.value == null) {
        setState(() => _watching = false);
        say(context, e);
      }
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

/// The camera scanner for a pairing code, on the phones alone by the button
/// that opens it ([_canScan]). Pops with the scanned text on a successful detect.
///
/// A refused camera is a page of its own rather than the scanner's raw error:
/// iOS asks once and never again, so the only way back is the app's page in
/// Settings, which the page opens there. Android asks again on the next open
/// until a second refusal, after which it is as silent as iOS; the page names
/// the path to its permission screen instead, since url_launcher has no URL
/// that opens one.
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
        errorBuilder: (context, error) =>
            error.errorCode == MobileScannerErrorCode.permissionDenied
                ? const _CameraRefused()
                : _pairingFailed(context, error.errorDetails?.message ??
                    error.errorCode.message),
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
        if (pairing.peerName case final name? when name.isNotEmpty) ...[
          const SizedBox(height: 4),
          mutedParagraph(
              context, 'The other device calls itself "$name".'),
        ],
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

class _CameraRefused extends StatelessWidget {
  const _CameraRefused();

  static bool get _iOS => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Entoli can't use the camera."),
            const SizedBox(height: 8),
            mutedParagraph(
                context,
                _iOS
                    ? "Allow it under Settings, Entoli, Camera, or go back and "
                        "paste the pairing code instead."
                    : "Allow it when Entoli asks. If it no longer asks, "
                        "allow it under Settings, Apps, Entoli, Permissions, "
                        "Camera, or go back and paste the pairing code "
                        "instead."),
            if (_iOS) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => unawaited(_openSettings()),
                child: const Text("Open Settings"),
              ),
            ],
          ],
        ),
      );

  // UIApplication.openSettingsURLString, which url_launcher opens like any
  // other URL; it lands on this app's own page.
  static Future<void> _openSettings() async {
    try {
      if (!await launchUrl(Uri.parse("app-settings:"))) {
        logFailure("sync", "the Settings app did not open");
      }
    } catch (e) {
      logFailure("sync", "the Settings app did not open", e);
    }
  }
}
