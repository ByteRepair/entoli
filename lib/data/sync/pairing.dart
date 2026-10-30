import "dart:async";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../core/tls.dart";

import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../domain/sync/lan_signaling.dart";
import "../../domain/sync/protocol.dart";
import "../../domain/sync/relay_signaling.dart";
import "channel.dart";
import "framing.dart";
import "handshake.dart";
import "peers.dart";
import "rtc_channel.dart";
import "signaling/lan_signaler.dart";
import "signaling/pairing_payload.dart";
import "signaling/relay_signaler.dart";

/// What a pairing window looks like while it is open. Replaced wholesale on
/// every change, so listeners see an immutable snapshot.
class PairingActivity {
  const PairingActivity({
    this.qr,
    this.code,
    this.stage = PairingStage.connecting,
    this.sas,
    this.peerName,
    this.error,
  });

  /// The `entoli-pair:` string behind the QR / paste field. Null when this
  /// device is only receiving a manual answer.
  final String? qr;
  final String? code;
  final PairingStage stage;
  final String? sas;

  /// The name the other device gave, where its handshake has arrived — what
  /// the paired screen and the codes-matched view say when they name it.
  /// Null before that.
  final String? peerName;
  final String? error;

  /// The same activity, changed where named. A field named null keeps what
  /// it was: the notes carry a snapshot's facts forward, so a copy that did
  /// not would drop one at every stage.
  PairingActivity copyWith({
    String? qr,
    String? code,
    PairingStage? stage,
    String? sas,
    String? peerName,
    String? error,
  }) =>
      PairingActivity(
        qr: qr ?? this.qr,
        code: code ?? this.code,
        stage: stage ?? this.stage,
        sas: sas ?? this.sas,
        peerName: peerName ?? this.peerName,
        error: error ?? this.error,
      );
}

enum PairingStage { connecting, confirming, done, failed }

/// Everything two Entolis do together before there are chats involved: find
/// each other, prove who they are, and stay online.
///
/// Wire rules live beside this — [Handshake] for the key exchange,
/// [SecureChannel] for what moves after it. What this owns is three
/// decisions:
///
/// * **Who speaks first.** The handshake initiator is always the WebRTC
///   *answer* side (`!weOffered` in [_establish]), so no extra message is
///   needed to decide, whichever route brought the two together.
/// * **Who may dial again.** A pairing window arms its one-time code; every
///   completed pair also arms a reconnect token derived from the pair's
///   secret, so paired devices redial without re-pairing while this app's
///   server is up.
/// * **What the relay learns.** Nothing readable. Rooms are derived from
///   pairing secrets, SDP blobs are opaque, and the channel keys come from
///   material that never crossed any network.
///
/// Nothing here knows what a chat is. A peer that reaches the end of
/// [_establish] is handed to [onReady], and everything it then says goes to
/// [onMessage] — which is where the halves that do know begin.
class SyncPairing {
  SyncPairing({
    required this.identity,
    required this.registry,
    required this._settings,
    String? Function()? turnPassword,
    required this._peers,
    required LanSignaling? Function() lanSignaling,
    required this.onMessage,
    required this.onPeerGone,
    required this.onReady,
    this._hostname,
    http.Client? client,
    RelayDial? relayDial,
  })  : _turnPassword = turnPassword ?? (() => null),
        _lanFactory = lanSignaling,
        _relayDial = relayDial ?? RelaySignaler.connect,
        _client = client ?? tlsClient();

  final SyncIdentity identity;
  final DeviceRegistry registry;

  /// The TURN credential, read from the secret store through the closure
  /// rather than from settings — where it no longer lives. Read per ICE
  /// config, the way the URL and username are: an edit reaches the next dial.
  final String? Function() _turnPassword;
  final AppSettings Function() _settings;
  final SyncPeers _peers;

  /// Where a message from a peer goes once there is a channel to carry it.
  final void Function(LivePeer peer, SyncMessage message) onMessage;

  /// A connection ended.
  final void Function(String deviceId) onPeerGone;

  /// A peer finished the handshake and is filed. Whatever this device has to
  /// say first goes out here.
  final Future<void> Function(LivePeer peer) onReady;

  /// What the machine calls itself, where it has a name — the default device
  /// name before the user picks one. Passed in rather than read here, so a
  /// test can name the machine.
  final String? _hostname;
  final LanSignaling? Function() _lanFactory;
  final RelayDial _relayDial;
  final http.Client _client;

  LanSignaling? _serverInstance;

  /// The LAN server, created once from the factory and cached so state
  /// (port, armed code, reconnect tokens) survives across calls.
  LanSignaling? get _server {
    _serverInstance ??= _lanFactory();
    return _serverInstance;
  }

  StreamSubscription<IncomingOffer>? _offers;

  /// The relay wait a pairing window opened, cancelled with it.
  StreamSubscription<Map<String, dynamic>>? _relayWindow;
  RelaySignaling? _relaySocket;

  _PendingManual? _pendingManual;
  Completer<bool>? _confirmation;

  /// The pairing happening right now, if any.
  final activity = ValueNotifier<PairingActivity?>(null);

  /// Starts listening for reconnects, so a desktop that has paired once can
  /// be dialed again after a restart without opening a window first.
  /// Cheap where nothing is paired: the server never starts.
  Future<void> ensureReady() async {
    // Read once: `FileDeviceRegistry.list` re-reads and re-parses the file
    // on every call, and this was asking three times over.
    final devices = await registry.list();
    for (final device in devices) {
      final secret = await registry.pairingSecret(device.id);
      if (secret != null) {
        _reconnects[RelaySignaler.roomFor(secret)] =
            (deviceId: device.id, psk: secret);
      }
    }
    // Before the early return below: a device with no pairings starts no
    // server, and still has a list of paired devices to draw.
    _peers.publish(devices);
    final server = _server;
    if (server == null || devices.isEmpty) return;
    await server.start();
    for (final token in _reconnects.keys) {
      server.allowReconnect(token);
    }
    // Answering is what was missing: the tokens above let an offer in, and
    // with nothing subscribed nobody ever replied to it.
    _watchOffers(server);
  }

  Future<void> dispose() async {
    cancelPairingWindow();
    await _serverInstance?.close();
  }

  String _nameOf(PairedDevice? device, PeerIdentity peer) =>
      (device?.name.isNotEmpty ?? false) ? device!.name : peer.name;

  /// Opens a pairing window: arms a code on the LAN server where this
  /// platform can listen, and joins the configured relay room when there is
  /// one. Throws where neither route exists.
  ///
  /// Exactly one window runs at a time; opening one closes the last.
  Future<PairingActivity> startPairingWindow() async {
    cancelPairingWindow();
    final server = _server;
    final relayUrl = _settings().syncRelayUrl ?? "";
    if (server == null && relayUrl.isEmpty) throw SignalingException(noRoute);

    final psk = generatePsk();
    String? qr;
    String? code;
    if (server != null) {
      final port = await server.start();
      code = generatePairingCode();
      server.arm(code);
      _windowPsk = psk;
      _watchOffers(server);
      final hosts = await server.addresses();
      qr = PairingOffer(
        kind: PairingOffer.lanKind,
        psk: psk,
        name: deviceName,
        hosts: hosts,
        port: port,
        code: code,
      ).encode();
    } else {
      qr = PairingOffer(
        kind: PairingOffer.relayKind,
        psk: psk,
        name: deviceName,
        relayUrl: relayUrl,
      ).encode();
      unawaited(_waitInRelayRoom(relayUrl, psk));
    }
    final opened =
        PairingActivity(qr: qr, code: code, stage: PairingStage.connecting);
    activity.value = opened;
    return opened;
  }

  /// Why there is no window to open.
  static const noRoute = "No way to be found: this build has no local "
      "network signaling and no relay URL is set.";

  void cancelPairingWindow() {
    _windowPsk = null;
    _relayWindow?.cancel();
    _relayWindow = null;
    unawaited(_relaySocket?.close());
    _relaySocket = null;
    _server?.disarm();
    // The offers subscription is *not* cancelled: it answers reconnects too,
    // and every pairing ends by closing its window. Cancelled here, the first
    // successful pair was also the last time anything answered a dial.
    cancelPairing();
  }

  /// Ends a pairing in flight, wherever it is: a pending codes-matched gate
  /// is answered no and the activity is dropped, so a screen parked on it
  /// loses its subject. The general verb — every pairing screen's back and
  /// Done is this one, on pages that opened no window; the window's verb
  /// above is the window's own teardown beside it.
  void cancelPairing() {
    _confirmation?.complete(false);
    _confirmation = null;
    activity.value = null;
  }

  /// Drops a pending manual invite, closing the peer connection it held
  /// open, and ends a pairing in flight beside it — the same
  /// route-teardown-then-general-drop shape the window's verb has, so the
  /// invite page's back and Done is one call either way: pending before the
  /// reply, gate answered no once the pair is completing.
  void cancelManualInvite() {
    final pending = _pendingManual;
    _pendingManual = null;
    if (pending != null) unawaited(pending.link.close());
    cancelPairing();
  }

  /// A joiner reads [text] — scanned or pasted — and completes its half.
  /// Manual invites cannot finish alone: the returned reply must go back to
  /// the inviting device before either side connects. Every other kind
  /// resolves once both ends are online.
  ///
  /// Throws [HandshakeException] or [SignalingException] with a message
  /// meant for the screen.
  Future<String?> pairWith(String text) async {
    final offer = PairingOffer.decode(text);
    if (offer == null) {
      throw const SignalingException("that is not an Entoli pairing code");
    }
    switch (offer.kind) {
      case PairingOffer.lanKind:
        await _joinOverLan(offer);
        return null;
      case PairingOffer.relayKind:
        await _joinOverRelay(offer);
        return null;
      case PairingOffer.offerKind:
        return _acceptManualInvite(offer);
      case PairingOffer.answerKind:
        // The other half of `createManualInvite`: this device made the offer
        // and is being handed the reply, so there is nothing to send back.
        await _completeManualPairing(offer);
        return null;
      default:
        throw SignalingException(
            "that code asks for ${offer.kind}, not pairing");
    }
  }

  /// The inviting device's half of a manual pair: build an invite blob and
  /// hold the connection open until [completeManualPairing] takes the reply.
  Future<String> createManualInvite() async {
    final psk = generatePsk();
    final link = await RtcLink.create(iceServers: iceServers());
    final sdp = await link.offer();
    _pendingManual = _PendingManual(link: link, psk: psk);
    return PairingOffer(
      kind: PairingOffer.offerKind,
      psk: psk,
      name: deviceName,
      sdp: sdp,
      tag: RelaySignaler.roomFor(psk),
    ).encode();
  }

  /// The invited device's half: answer the invite and hand back what to
  /// paste into the inviting device. Connecting continues on its own; the
  /// reply reaching the inviter is what completes the pair.
  Future<String> _acceptManualInvite(PairingOffer invite) async {
    final link = await RtcLink.create(iceServers: iceServers());
    final answerSdp = await link.answer(invite.sdp);
    // The pairing card opens here: the answered handshake runs under no
    // window, so the codes-matched gate has this card to ask on and the
    // paired or failed screen somewhere to end up.
    activity.value = const PairingActivity();
    unawaited(_establish(
      link: await link.open(),
      weOffered: false,
      psk: invite.psk,
      knownDeviceId: null,
    ).catchError((Object _) => link.close()));
    return PairingOffer(
      kind: PairingOffer.answerKind,
      psk: "",
      name: deviceName,
      sdp: answerSdp,
      tag: invite.tag,
    ).encode();
  }

  /// Takes the invited device's reply and finishes the pending invite.
  Future<void> _completeManualPairing(PairingOffer answer) async {
    final pending = _pendingManual;
    if (pending == null) {
      throw const SignalingException("no invite waiting for an answer");
    }
    if (pending.pskTag != answer.tag) {
      throw const SignalingException("that answer belongs to another invite");
    }
    _pendingManual = null;
    // The card is open while the pair completes: on this end the handshake
    // also runs with no window open, and the gate asks on it.
    activity.value = const PairingActivity();
    try {
      await pending.link.acceptAnswer(answer.sdp);
      await _establish(
        link: await pending.link.open(),
        weOffered: true,
        psk: pending.psk,
        knownDeviceId: null,
      );
    } catch (_) {
      unawaited(pending.link.close());
      rethrow;
    }
  }

  /// The human said yes/no at the codes-matched dialog.
  void confirmPairing(bool ok) {
    _confirmation?.complete(ok);
    _confirmation = null;
  }

  // ---------------------------------------------- dialling a known device

  /// Dial a paired device again: its last known address first, then the
  /// relay setting if one is configured. Over the relay both ends must be
  /// dialling around the same moment — the room exists while both are in it.
  Future<void> connect(String deviceId) async {
    final device = await registry.byId(deviceId);
    final secret = await registry.pairingSecret(deviceId);
    if (device == null || secret == null) {
      throw SignalingException("$deviceId was never paired here");
    }
    _peers.setStatus(deviceId, name: device.name, status: PeerStatus.connecting);
    final token = RelaySignaler.roomFor(secret);

    Object? failure;
    final server = _server;
    // Where it was last seen, each on the port it was seen on and the one it
    // would normally be on — a device that simply restarted is at the second.
    // Then, where those have all gone stale, whoever answers a broadcast for
    // this pair — asked only then, since asking takes its two seconds.
    for (final candidates in [
      () async => [
            for (final address in device.addresses) ...[
              address,
              "${address.substring(0, address.lastIndexOf(":"))}"
                  ":$preferredSignalingPort",
            ],
          ],
      if (server != null) () => server.discover(token),
    ]) {
      final addresses = await candidates();
      if (addresses.isEmpty) continue;
      try {
        await _dialOverLan(
          addresses: addresses,
          token: token,
          psk: secret,
          knownDeviceId: deviceId,
        );
        return;
      } catch (error) {
        failure = error;
      }
    }
    final relayUrl = _settings().syncRelayUrl ?? "";
    if (relayUrl.isNotEmpty) {
      try {
        await _dialViaRelay(relayUrl, secret, deviceId);
        return;
      } catch (error) {
        failure = error;
      }
    }
    // One sentence, said twice: the row keeps the reason and the caller
    // throws it with the device's name on the front. A null error on the row
    // was the honest half of this going missing.
    final reason = failure?.toString() ?? "no route configured";
    _peers.setStatus(deviceId,
        name: device.name, status: PeerStatus.error, error: reason);
    throw SignalingException("could not reach ${device.name}: $reason");
  }

  Future<void> disconnect(String deviceId) async {
    await _peers.remove(deviceId)?.close();
    _peers.markOffline(deviceId);
  }

  /// What the other device files this one under.
  String get deviceName => _settings().deviceName ?? defaultDeviceName;

  /// What it would be called with nothing set — the machine's own name where
  /// there is one, since that is what its owner already calls it, and four
  /// characters of the key's digest otherwise, which at least cannot
  /// collide. Its own getter because the Sync page's field wants exactly
  /// this: the hint has to go on saying what the default is after a name
  /// has been typed over it.
  ///
  /// Four, not five of the grouped fingerprint: the next slice there is the
  /// group's separating space, and this name once trailed by one. The slice
  /// is [SyncIdentity.digest]'s rather than the display string's, so a
  /// regrouped presentation would not change a nameless machine announces.
  String get defaultDeviceName =>
      _hostname ?? "Entoli ${identity.digest.substring(0, 4)}";

  /// Every host:port a peer could dial this device back on, empty where it is
  /// not listening.
  Future<List<String>> _dialbackAddresses() async {
    final server = _server;
    if (server == null) return const [];
    final port = server.port ?? await server.start();
    return [for (final host in await server.addresses()) "$host:$port"];
  }

  List<Map<String, Object>> iceServers() {
    final servers = [
      for (final url in RtcLink.defaultStun) {"urls": url},
    ];
    final turn = _settings().turnUrl;
    if (turn != null && turn.isNotEmpty) {
      servers.add({
        "urls": turn,
        "username": ?_settings().turnUsername,
        "credential": ?_turnPassword(),
      });
    }
    return servers;
  }

  // ------------------------------------------------------------ internals

  /// The host's route: offers arrive through the armed server and are
  /// answered straight back. The pairing secret is the window's.
  /// Answers offers for as long as the server is up — not only while a
  /// pairing window is open. A paired device redialling arrives here with a
  /// reconnect token and no window in sight; before this, the server let the
  /// offer in and nothing was subscribed to answer it, so every reconnect
  /// waited out the dialling side's timeout.
  void _watchOffers(LanSignaling server) {
    _offers?.cancel();
    _offers = server.offers.listen((incoming) {
      () async {
        // Which pair it is decides the secret, and whether this is a first
        // pairing at all: a token names a device already known, so its
        // handshake is pinned to that key and skips the codes-matched gate.
        final known = incoming.token == null ? null : _reconnects[incoming.token];
        final psk = known?.psk ?? _windowPsk;
        if (psk == null) return;
        RtcLink? link;
        try {
          link = await RtcLink.create(iceServers: iceServers());
          final answerSdp = await link.answer(incoming.sdp);
          server.postAnswer(incoming.id, answerSdp);
          await _establish(
            link: await link.open(),
            weOffered: false,
            psk: psk,
            knownDeviceId: known?.deviceId,
          );
        } catch (error) {
          logFailure("sync", "answering an offer failed", error);
          await link?.close();
          _fail(error);
        }
      }();
    });
  }

  /// Reconnect token to the pair it belongs to. Filled from the registry at
  /// startup and by every completed pairing, so an offer arriving under a
  /// token can be answered with that pair's secret.
  final _reconnects = <String, ({String deviceId, String psk})>{};

  /// The secret a pairing window is armed with, for offers that carry a code
  /// rather than a token. Null when no window is open, which is what makes a
  /// stranger's offer unanswerable rather than merely refused.
  String? _windowPsk;

  void _allowReconnect(String deviceId, String psk) {
    final token = RelaySignaler.roomFor(psk);
    _reconnects[token] = (deviceId: deviceId, psk: psk);
    _server?.allowReconnect(token);
  }

  /// Whether a device holding [psk] would be let in again. False after a
  /// revoke, which is the whole point of one.
  bool admitsReconnect(String psk) =>
      _reconnects.containsKey(RelaySignaler.roomFor(psk));

  /// The shared tail's gate, driven directly: a test pins the refusal rather
  /// than racing a handshake to reach it. Public like [establishForTest] is;
  /// the hub's own `visibleForTesting` wrapper is what bounds it.
  Future<bool> confirmGateForTest(String sas, String peerName,
          {required bool isNew}) =>
      _sasGate(sas, peerName, isNew: isNew);

  /// Unpairs [deviceId]. The secret is read before the registry loses it:
  /// the token derived from it is what admits the device, and clearing
  /// everything *except* that left a revoked device still dialling in, and
  /// still being answered, until something restarted.
  Future<void> forgetDevice(String deviceId) async {
    final secret = await registry.pairingSecret(deviceId);
    if (secret != null) _forgetReconnect(secret);
    await registry.remove(deviceId);
  }

  void _forgetReconnect(String psk) {
    final token = RelaySignaler.roomFor(psk);
    _reconnects.remove(token);
    _server?.refuseReconnect(token);
  }

  /// The generator's route over the relay: sit in the room derived from the
  /// window's secret until a joiner's offer arrives, answer it.
  Future<void> _waitInRelayRoom(String relayUrl, String psk) async {
    try {
      final closer = await _relayDial(
          relayUrl: relayUrl, room: RelaySignaler.roomFor(psk), role: "i");
      _relaySocket = closer;
      final messages = closer.messages;
      _relayWindow = messages.listen((message) {
        if (!message.containsKey("offer")) return;
        () async {
          RtcLink? link;
          try {
            link = await RtcLink.create(iceServers: iceServers());
            final answerSdp = await link.answer(message["offer"] as String);
            await closer.send({"answer": answerSdp});
            await _establish(
              link: await link.open(),
              weOffered: false,
              psk: psk,
              knownDeviceId: null,
            );
          } catch (error) {
            await link?.close();
            _fail(error);
          }
        }();
      }, onError: (Object error) => _fail(error));
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _joinOverLan(PairingOffer payload) async {
    activity.value = const PairingActivity();
    try {
      await _dialOverLan(
        addresses: [for (final host in payload.hosts) "$host:${payload.port}"],
        code: payload.code,
        psk: payload.psk,
      );
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  /// Offer, exchange, establish — the whole of a dial over a local network.
  /// Both callers are the same seven steps; written out twice they had
  /// already diverged, with only one of them learning to try more than the
  /// port it was told about.
  Future<void> _dialOverLan({
    required List<String> addresses,
    required String psk,
    String code = "",
    String token = "",
    String? knownDeviceId,
  }) async {
    final link = await RtcLink.create(iceServers: iceServers());
    try {
      final sdp = await link.offer();
      final signaler = LanSignaler(client: _client);
      final (:answer, :address) = await signaler.exchange(
          addresses: addresses, code: code, token: token, offerSdp: sdp);
      await link.acceptAnswer(answer);
      await _establish(
        link: await link.open(),
        weOffered: true,
        psk: psk,
        knownDeviceId: knownDeviceId,
        address: address,
      );
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  Future<void> _joinOverRelay(PairingOffer payload) async {
    activity.value = const PairingActivity();
    try {
      await _dialViaRelay(payload.relayUrl, payload.psk, null);
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  /// Fresh pairings: the joiner offers ("j"), the window holds ("i").
  /// Reconnects: the larger id offers, deterministically on both ends.
  Future<void> _dialViaRelay(String relayUrl, String psk, String? knownId) async {
    final room = RelaySignaler.roomFor(psk);
    final weOffer = knownId == null || identity.id.compareTo(knownId) > 0;
    final closer = await _relayDial(
        relayUrl: relayUrl, room: room, role: weOffer ? "i" : "j");
    try {
      final link = await RtcLink.create(iceServers: iceServers());
      try {
        if (weOffer) {
          await closer.send({"offer": await link.offer()});
          final message = await closer.waitFor("answer");
          await link.acceptAnswer(message["answer"] as String);
        } else {
          final message = await closer.waitFor("offer");
          await closer.send({"answer": await link.answer(message["offer"] as String)});
        }
        await _establish(
          link: await link.open(),
          weOffered: weOffer,
          psk: psk,
          knownDeviceId: knownId,
        );
      } catch (_) {
        await link.close();
        rethrow;
      }
    } finally {
      unawaited(closer.close());
      if (identical(_relaySocket, closer)) _relaySocket = null;
    }
  }

  /// Tests drive the shared tail directly: a loopback [ByteChannel] stands in
  /// for the data channel, so everything from the handshake up is exercised
  /// with no transport, offer, or signaling underneath.
  Future<void> establishForTest({
    required ByteChannel link,
    required bool weOffered,
    required String psk,
    String? knownDeviceId,
  }) {
    // Every real route opens the pairing card before the handshake; without
    // one the codes-matched gate has nowhere to ask and never resolves.
    if (knownDeviceId == null) activity.value = const PairingActivity();
    return _establish(
      link: link,
      weOffered: weOffered,
      psk: psk,
      knownDeviceId: knownDeviceId,
    );
  }

  /// Shared tail of every route: handshake across the open data channel,
  /// the codes-matched gate for first pairings, hello, and filing the peer.
  Future<void> _establish({
    required ByteChannel link,
    required bool weOffered,
    required String psk,
    required String? knownDeviceId,
    String? address,
  }) async {
    final handshake =
        Handshake(identity, pairingSecret: psk, name: deviceName);
    SecureChannel? channel;
    try {
      channel = await SecureChannel.open(
        link,
        handshake: handshake,
        initiator: !weOffered,
      );
      channel.listen();
      final peer = handshake.peer!;
      if (knownDeviceId != null) handshake.requirePeerId(knownDeviceId);

      // The codes are compared before anything is read or sent. The other
      // side answers the moment *its* human has confirmed, which may be well
      // before ours has — and what it sends is held by the channel until the
      // reader below attaches, so there is nothing to be careful about here.
      // It cost four bugs to stop needing that care; see the framing.
      if (!await _sasGate(
        handshake.sas!,
        peer.name,
        isNew: knownDeviceId == null,
      )) {
        throw const HandshakeException("the codes did not match");
      }

      final deviceId = peer.id;
      final peerDevice = await registry.byId(deviceId);
      final live = LivePeer(channel,
          deviceId: deviceId,
          deviceName: _nameOf(peerDevice, peer),
          onClose: () => onPeerGone(deviceId));
      final hello = Completer<Map<String, dynamic>>();
      live.handle = (message) => onMessage(live, message);
      live.pump = channel.jsonIncoming.listen(
        (json) {
          // The hello is not a [SyncMessage]: it is the name and dial-back
          // address either side sends before speaking the protocol at all.
          // The version was checked by the handshake.
          if (!hello.isCompleted) {
            if (json["t"] == "hello") hello.complete(json);
            return;
          }
          try {
            live.enqueue(SyncMessage.fromJson(json));
          } catch (error) {
            // A frame that does not parse is a broken peer; drop the link
            // rather than guess at what it meant.
            logFailure("sync", "unreadable frame from $deviceId", error);
            unawaited(live.close());
          }
        },
        // A peer that goes away mid-exchange has to fail the hello too, or
        // this side waits out the timeout below for an answer that can no
        // longer come.
        onError: (Object error) {
          logFailure("sync", "link to $deviceId failed", error);
          if (!hello.isCompleted) hello.completeError(error);
          unawaited(live.close());
        },
        onDone: () {
          if (!hello.isCompleted) {
            hello.completeError(const ChannelClosedException());
          }
          unawaited(live.close());
        },
      );

      await channel.sendJson({
        "t": "hello",
        "id": identity.id,
        "name": deviceName,
        // Where this device can be dialled back, if it listens at all. Only
        // the side that dialled knows the other's address otherwise, so only
        // that side could ever reconnect — the other one had no route and
        // said so.
        "addrs": await _dialbackAddresses(),
      });
      final reply = await hello.future.timeout(const Duration(seconds: 15));

      var device = peerDevice;
      if (device == null) {
        device = PairedDevice(
          id: deviceId,
          name: live.deviceName,
          publicKey: peer.publicKeyB64,
          addedAt: DateTime.now(),
        );
        await registry.add(device);
        await registry.setPairingSecret(deviceId, psk);
      }
      // The registry's own verb rather than the same two fields written here:
      // when a device was last reached, and where, is what a registry is for.
      // The one we dialled first, since it answered, then every one it gave:
      // on the side that was dialled, those are the only ones there are.
      await registry.markSeen(deviceId, addresses: {
        ?address,
        ...?(reply["addrs"] as List<Object?>?)?.cast<String>(),
      }.toList());

      _peers.adopt(live);
      _peers.setStatus(deviceId,
          name: device.name, status: PeerStatus.online);

      // What this device serves. The mirror side answers this with
      // chatOpens for whatever it follows.
      await onReady(live);

      // From here on, this pair can redial without the window — and this
      // device starts listening for one, which before a pairing it had no
      // reason to be doing.
      _allowReconnect(deviceId, psk);
      unawaited(ensureReady());
      _note(PairingStage.done, peerName: live.deviceName);
    } catch (error) {
      logFailure("sync", "could not establish a channel", error);
      await channel?.close();
      _fail(error);
      rethrow;
    }
  }

  /// First pairings pause here for two humans to compare codes; reconnects
  /// are pinned-key authenticated and walk straight through. The peer's name
  /// rides with the SAS, so the confirm says who it is asking about. A gate
  /// asks only where there is a pairing to ask on: the arm a human backed out
  /// of — its page's back nulled the activity while the dial was still
  /// connecting — arrives here with no screen the codes could be shown on,
  /// and has to fail rather than wait out a confirmation nobody can give.
  Future<bool> _sasGate(
      String sas, String peerName, {required bool isNew}) async {
    if (!isNew) return true;
    if (activity.value == null) {
      throw const HandshakeException(
          "the pairing ended before the codes were confirmed");
    }
    _note(PairingStage.confirming, sas: sas, peerName: peerName);
    final confirmation = _confirmation = Completer<bool>();
    return confirmation.future;
  }

  void _note(PairingStage stage, {String? sas, String? peerName}) {
    final current = activity.value;
    if (current == null) return;
    activity.value =
        current.copyWith(stage: stage, sas: sas, peerName: peerName);
  }
  void _fail(Object error) {
    logFailure("sync", "pairing failed", error);
    final current = activity.value;
    if (current == null || current.stage == PairingStage.done) return;
    activity.value = current.copyWith(
      stage: PairingStage.failed,
      error: error.toString(),
    );
  }
}

class _PendingManual {
  _PendingManual({required this.link, required this.psk});

  final RtcLink link;
  final String psk;
  String get pskTag => RelaySignaler.roomFor(psk);
}
