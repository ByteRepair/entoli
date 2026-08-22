import "dart:async";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../core/config.dart";
import "../../domain/app_settings.dart";
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../domain/sync/lan_signaling.dart";
import "channel.dart";
import "framing.dart";
import "handshake.dart";
import "rtc_channel.dart";
import "signaling/lan_signaler.dart";
import "signaling/pairing_payload.dart";
import "signaling/relay_signaler.dart";

export "signaling/pairing_payload.dart"
    show PairingOffer, generatePairingCode, generatePsk;

/// How one paired device stands right now, as the Sync page draws it.
enum PeerStatus { connecting, online, offline, error }

class PeerState {
  PeerState({
    required this.deviceId,
    required this.name,
    required this.status,
    this.error,
  });

  final String deviceId;
  final String name;
  final PeerStatus status;
  final String? error;
}

/// What a pairing window looks like while it is open. Replaced wholesale on
/// every change, so listeners see an immutable snapshot.
class PairingActivity {
  const PairingActivity({
    this.qr,
    this.code,
    this.stage = PairingStage.connecting,
    this.sas,
    this.error,
  });

  /// The `entoli-pair:` string behind the QR / paste field. Null when this
  /// device is only receiving a manual answer.
  final String? qr;
  final String? code;
  final PairingStage stage;
  final String? sas;
  final String? error;
}

enum PairingStage { connecting, confirming, done, failed }

/// Everything two Entolis do together before there are chats involved: find
/// each other, prove who they are, and stay online.
///
/// Wire rules live below — [Handshake] for the key exchange, [SecureChannel]
/// for what moves after it. This file owns three decisions:
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
class SyncHub {
  SyncHub({
    required this.identity,
    required this.registry,
    required AppConfig config,
    required AppSettings Function() settings,
    required LanSignaling? Function() lanSignaling,
    http.Client? client,
  })  : _settings = settings,
        _lanFactory = lanSignaling,
        _client = client ?? http.Client();

  final SyncIdentity identity;
  final DeviceRegistry registry;

  final AppSettings Function() _settings;
  final LanSignaling? Function() _lanFactory;
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
  RelaySignaler? _relaySocket;

  _PendingManual? _pendingManual;
  Completer<bool>? _confirmation;
  final _live = <String, _LivePeer>{};

  /// Every paired device with how it stands. The UI's whole view of sync.
  final peers = ValueNotifier<Map<String, PeerState>>({});

  /// The pairing happening right now, if any.
  final pairing = ValueNotifier<PairingActivity?>(null);

  // ------------------------------------------------------------ lifecycle

  /// Starts listening for reconnects, so a desktop that has paired once can
  /// be dialed again after a restart without opening a window first.
  /// Cheap where nothing is paired: the server never starts.
  Future<void> ensureReady() async {
    final server = _server;
    if (server == null || (await registry.list()).isEmpty) return;
    await server.start();
    for (final device in await registry.list()) {
      final secret = await registry.pairingSecret(device.id);
      if (secret != null) server.allowReconnect(RelaySignaler.roomFor(secret));
    }
  }

  Future<void> dispose() async {
    cancelPairingWindow();
    for (final peer in _live.values) {
      await peer.close();
    }
    _live.clear();
    await _serverInstance?.close();
  }

  // -------------------------------------------------------------- pairing

  /// Opens a pairing window: arms a code on the LAN server where this
  /// platform can listen, and joins the configured relay room when there is
  /// one. Returns what the QR shows; null where neither route exists — a
  /// browser pairs from the other side instead.
  ///
  /// Exactly one window runs at a time; opening one closes the last.
  Future<PairingActivity?> startPairingWindow() async {
    cancelPairingWindow();
    final server = _server;
    final lanAvailable = server != null && !kIsWeb;
    final relayUrl = _settings().syncRelayUrl ?? "";
    if (!lanAvailable && relayUrl.isEmpty) return null;

    final psk = generatePsk();
    String? qr;
    String? code;
    if (lanAvailable) {
      final port = await server.start();
      code = generatePairingCode();
      server.arm(code);
      _watchOffers(server, psk);
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
    final activity =
        PairingActivity(qr: qr, code: code, stage: PairingStage.connecting);
    pairing.value = activity;
    return activity;
  }

  void cancelPairingWindow() {
    _confirmation?.complete(false);
    _confirmation = null;
    _relayWindow?.cancel();
    _relayWindow = null;
    unawaited(_relaySocket?.close());
    _relaySocket = null;
    _server?.disarm();
    _offers?.cancel();
    _offers = null;
    pairing.value = null;
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
  Future<String> acceptManualInvite(String inviteText) async {
    final invite = PairingOffer.decode(inviteText);
    if (invite == null || invite.kind != PairingOffer.offerKind) {
      throw const SignalingException("that is not an Entoli invite");
    }
    return _acceptManualInvite(invite);
  }

  Future<String> _acceptManualInvite(PairingOffer invite) async {
    final link = await RtcLink.create(iceServers: iceServers());
    final answerSdp = await link.answer(invite.sdp);
    unawaited(_establish(
      link: await link.open(),
      weOffered: false,
      psk: invite.psk,
      knownDeviceId: null,
      onFailed: () => link.close(),
    ));
    return PairingOffer(
      kind: PairingOffer.answerKind,
      psk: "",
      name: deviceName,
      sdp: answerSdp,
      tag: invite.tag,
    ).encode();
  }

  /// Takes the invited device's reply and finishes the pending invite.
  Future<void> completeManualPairing(String answerText) async {
    final answer = PairingOffer.decode(answerText);
    if (answer == null || answer.kind != PairingOffer.answerKind) {
      throw const SignalingException("that is not an Entoli answer");
    }
    final pending = _pendingManual;
    if (pending == null) {
      throw const SignalingException("no invite waiting for an answer");
    }
    if (pending.pskTag != answer.tag) {
      throw const SignalingException("that answer belongs to another invite");
    }
    _pendingManual = null;
    try {
      await pending.link.acceptAnswer(answer.sdp);
      await _establish(
        link: await pending.link.open(),
        weOffered: true,
        psk: pending.psk,
        knownDeviceId: null,
        onFailed: () => pending.link.close(),
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

  // ------------------------------------------------------------- presence

  /// Dial a paired device again: its last known address first, then the
  /// relay setting if one is configured. Over the relay both ends must be
  /// dialling around the same moment — the room exists while both are in it.
  Future<void> connect(String deviceId) async {
    final device = await registry.byId(deviceId);
    final secret = await registry.pairingSecret(deviceId);
    if (device == null || secret == null) {
      throw SignalingException("$deviceId was never paired here");
    }
    _setStatus(deviceId, name: device.name, status: PeerStatus.connecting);
    final token = RelaySignaler.roomFor(secret);

    Object? failure;
    final address = device.lastAddress;
    if (address != null && address.contains(":")) {
      final at = address.lastIndexOf(":");
      try {
        final link = await RtcLink.create(iceServers: iceServers());
        final sdp = await link.offer();
        final signaler = LanSignaler(client: _client);
        try {
          final answer = await signaler.exchange(
            hosts: [address.substring(0, at)],
            port: int.parse(address.substring(at + 1)),
            token: token,
            offerSdp: sdp,
          );
          await link.acceptAnswer(answer);
          await _establish(
            link: await link.open(),
            weOffered: true,
            psk: secret,
            knownDeviceId: deviceId,
            address: address,
            onFailed: () => link.close(),
          );
          return;
        } finally {
          signaler.close();
        }
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
    _setStatus(deviceId, name: device.name, status: PeerStatus.error,
        error: failure?.toString());
    throw SignalingException(
        "could not reach ${device.name}: ${failure ?? "no route configured"}");
  }

  Future<void> disconnect(String deviceId) async {
    await _live.remove(deviceId)?.close();
    _markOffline(deviceId);
  }

  /// Unpairs: drops the record, its secret, and any live connection. The
  /// other device keeps ours until someone revokes there too.
  Future<void> revoke(String deviceId) async {
    await _live.remove(deviceId)?.close();
    await registry.remove(deviceId);
    _refreshPeers();
  }

  String get deviceName =>
      _settings().deviceName ??
      "Entoli ${identity.fingerprint.substring(0, 5)}";

  List<Map<String, Object>> iceServers() {
    final servers = [
      for (final url in RtcLink.defaultStun) {"urls": url},
    ];
    final turn = _settings().turnUrl;
    if (turn != null && turn.isNotEmpty) {
      servers.add({
        "urls": turn,
        if (_settings().turnUsername case final username?) "username": username,
        if (_settings().turnPassword case final password?)
          "credential": password,
      });
    }
    return servers;
  }

  // ------------------------------------------------------------ internals

  /// The host's route: offers arrive through the armed server and are
  /// answered straight back. The pairing secret is the window's.
  void _watchOffers(LanSignaling server, String psk) {
    _offers?.cancel();
    _offers = server.offers.listen((incoming) {
      () async {
        RtcLink? link;
        try {
          link = await RtcLink.create(iceServers: iceServers());
          final answerSdp = await link.answer(incoming.sdp);
          server.postAnswer(incoming.id, answerSdp);
          await _establish(
            link: await link.open(),
            weOffered: false,
            psk: psk,
            knownDeviceId: null,
            onFailed: () => link!.close(),
          );
        } catch (error) {
          await link?.close();
          _fail(error);
        }
      }();
    });
  }

  /// The generator's route over the relay: sit in the room derived from the
  /// window's secret until a joiner's offer arrives, answer it.
  Future<void> _waitInRelayRoom(String relayUrl, String psk) async {
    try {
      final closer = await RelaySignaler.connect(
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
              onFailed: () => link!.close(),
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
    pairing.value = const PairingActivity();
    final link = await RtcLink.create(iceServers: iceServers());
    try {
      final sdp = await link.offer();
      final signaler = LanSignaler(client: _client);
      String answer;
      try {
        answer = await signaler.exchange(
          hosts: payload.hosts,
          port: payload.port,
          code: payload.code,
          offerSdp: sdp,
        );
      } finally {
        signaler.close();
      }
      await link.acceptAnswer(answer);
      await _establish(
        link: await link.open(),
        weOffered: true,
        psk: payload.psk,
        knownDeviceId: null,
        address: "${payload.hosts.first}:${payload.port}",
        onFailed: () => link.close(),
      );
    } catch (error) {
      await link.close();
      _fail(error);
      rethrow;
    }
  }

  Future<void> _joinOverRelay(PairingOffer payload) async {
    pairing.value = const PairingActivity();
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
    final closer = await RelaySignaler.connect(
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
          onFailed: () => link.close(),
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

  /// Shared tail of every route: handshake across the open data channel,
  /// the codes-matched gate for first pairings, hello, and filing the peer.
  Future<void> _establish({
    required ByteChannel link,
    required bool weOffered,
    required String psk,
    required String? knownDeviceId,
    String? address,
    required Future<void> Function() onFailed,
  }) async {
    final handshake = Handshake(identity, pairingSecret: psk);
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

      if (await _sasGate(handshake.sas!, isNew: knownDeviceId == null) ==
          false) {
        throw const HandshakeException("the codes did not match");
      }

      await channel.sendJson({
        "t": "hello",
        "proto": SyncIdentity.protocolVersion,
        "id": identity.id,
        "name": deviceName,
      });
      final reply = await channel.jsonIncoming
          .firstWhere((m) => m["t"] == "hello")
          .timeout(const Duration(seconds: 15));
      if (reply["proto"] != SyncIdentity.protocolVersion) {
        throw HandshakeException("the other device runs protocol ${reply["proto"]}");
      }

      final deviceId = peer.id;
      var device = await registry.byId(deviceId);
      if (device == null) {
        device = PairedDevice(
          id: deviceId,
          name: (reply["name"] as String?)?.isNotEmpty == true
              ? reply["name"] as String
              : peer.name,
          publicKey: peer.publicKeyB64,
          addedAt: DateTime.now(),
        );
        await registry.setPairingSecret(deviceId, psk);
      }
      device
        ..lastSeenAt = DateTime.now()
        ..lastAddress = address ?? device.lastAddress;
      await registry.add(device);

      _live[deviceId]?.close();
      _live[deviceId] = _LivePeer(channel, onClose: () => _markOffline(deviceId));
      _setStatus(deviceId,
          name: device.name, status: PeerStatus.online);

      // From here on, this pair can redial without the window.
      _server?.allowReconnect(RelaySignaler.roomFor(psk));
      _note(PairingStage.done);
    } catch (error) {
      await channel?.close();
      unawaited(onFailed());
      _fail(error);
      rethrow;
    }
  }

  /// First pairings pause here for two humans to compare codes; reconnects
  /// are pinned-key authenticated and walk straight through.
  Future<bool> _sasGate(String sas, {required bool isNew}) async {
    if (!isNew) return true;
    _note(PairingStage.confirming, sas: sas);
    final confirmation = _confirmation = Completer<bool>();
    return confirmation.future;
  }

  void _setStatus(String deviceId,
      {required String name, required PeerStatus status, String? error}) {
    peers.value = {
      ...peers.value,
      deviceId: PeerState(
        deviceId: deviceId,
        name: name,
        status: status,
        error: error,
      ),
    };
  }

  void _markOffline(String deviceId) {
    final existing = peers.value[deviceId];
    if (existing == null || existing.status == PeerStatus.error) return;
    peers.value = {
      ...peers.value,
      deviceId: PeerState(
        deviceId: deviceId,
        name: existing.name,
        status: PeerStatus.offline,
      ),
    };
  }

  void _refreshPeers() {
    registry.list().then((devices) {
      final next = {...peers.value};
      for (final device in devices) {
        next.putIfAbsent(
          device.id,
          () => PeerState(
              deviceId: device.id, name: device.name, status: PeerStatus.offline),
        );
      }
      peers.value = next;
    });
  }

  void _note(PairingStage stage, {String? sas}) {
    final current = pairing.value;
    if (current == null) return;
    pairing.value = PairingActivity(
      qr: current.qr,
      code: current.code,
      stage: stage,
      sas: sas ?? current.sas,
    );
  }

  void _fail(Object error) {
    final current = pairing.value;
    if (current == null || current.stage == PairingStage.done) return;
    pairing.value = PairingActivity(
      qr: current.qr,
      code: current.code,
      stage: PairingStage.failed,
      sas: current.sas,
      error: error.toString(),
    );
  }
}

class _LivePeer {
  _LivePeer(this.channel, {required void Function() onClose})
      : _onClose = onClose;

  final SecureChannel channel;
  final void Function() _onClose;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await channel.close();
    _onClose();
  }
}

class _PendingManual {
  _PendingManual({required this.link, required this.psk});

  final RtcLink link;
  final String psk;
  String get pskTag => RelaySignaler.roomFor(psk);
}
