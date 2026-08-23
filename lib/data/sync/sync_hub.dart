import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../core/config.dart";
import "../../domain/app_settings.dart";
import "../../domain/chat_log.dart" show ChatRecord;
import "../../domain/chat_meta.dart";
import "../../domain/chat_repository.dart";
import "../../domain/models.dart" show ChatState;
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../domain/sync/lan_signaling.dart";
import "../../domain/sync/protocol.dart";
import "channel.dart";
import "framing.dart";
import "handshake.dart";
import "rtc_channel.dart";
import "signaling/lan_signaler.dart";
import "signaling/pairing_payload.dart";
import "signaling/relay_signaler.dart";
import "sync_byte_cache.dart";

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

/// One of a peer's chats, as this device mirrors it. RAM-only: nothing here
/// is ever written to the data directory, so no backup and no IndexedDB
/// carries it.
class MirrorChat {
  MirrorChat({
    required this.peerId,
    required this.deviceName,
    required this.state,
    required this.meta,
    List<ChatRecord>? records,
    required this.totalLines,
  }) : records = records ?? [];

  final String peerId;

  /// The home device's name, as its hello carried it — what the sidebar's
  /// Remotes rows show under the title.
  final String deviceName;
  ChatState state;
  ChatMeta meta;
  List<ChatRecord> records;

  /// How long the log was at the peer's end when last heard from. A mirror
  /// whose record count is short of this is stale by that many records.
  int totalLines;

  @override
  String toString() => "MirrorChat(${state.id}, ${records.length}/$totalLines)";
}

/// What the sidebar's Remotes section draws: one remote chat with who owns
/// it and whether the connection to them is up.
class RemoteChatEntry {
  const RemoteChatEntry({
    required this.chatId,
    required this.deviceId,
    required this.deviceName,
    required this.state,
    required this.online,
  });

  final String chatId;
  final String deviceId;
  final String deviceName;
  final ChatState state;
  final bool online;
}

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
    required this._settings,
    required LanSignaling? Function() lanSignaling,
    http.Client? client,
  })  : _lanFactory = lanSignaling,
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

  // ------------------------------------------------------------- mirroring

  ChatRepository? _repo;
  StreamSubscription<RepoEvent>? _changesSub;
  Timer? _pingTimer;

  /// The peer's chats this device mirrors, by chat id. Survives a disconnect
  /// as a stale snapshot; a reconnect replaces it wholesale with fresh data.
  final _mirrors = <String, MirrorChat>{};

  /// Chat ids being followed across reconnects — what [followChat] added and
  /// [unfollowChat] has not removed. On every welcome these are re-opened
  /// from where the mirror already is.
  final _desired = <String>{};

  /// Chat ids whose content changed since the last notice. The mirror
  /// controllers rebuild from here.
  /// Mirrored attachments, held only as long as the mirror is. Owned here
  /// rather than beside the page that shows them so that a mirror going
  /// takes its megabytes with it.
  final byteCache = SyncByteCache();

  final _mirrorUpdates = StreamController<String>.broadcast();

  Stream<String> get mirrorUpdates => _mirrorUpdates.stream;

  /// The Remotes section of the sidebar: one entry per mirrored chat, flat,
  /// rebuilt whenever anything under it moves.
  final remotes = ValueNotifier<List<RemoteChatEntry>>(const []);

  MirrorChat? mirror(String chatId) => _mirrors[chatId];

  /// Whether the connection to [chatId]'s home device is up. False for a
  /// stale snapshot: the page disables the composer and shows its banner.
  bool isChatOnline(String chatId) =>
      _live.containsKey(_mirrors[chatId]?.peerId);

  int _resourceSeq = 0;
  final _pendingResources = <String, _ResourceTransfer>{};

  /// The repository arrives after construction — the container that holds it
  /// does not exist yet when [SyncHub] is built. Serving-side everything is
  /// inert until this is called.
  void attach(ChatRepository repo) {
    if (_repo != null) return;
    _repo = repo;
    _changesSub = repo.changes.listen(_onRepoEvent);
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) => _ping());
  }

  void followChat(String chatId) {
    _desired.add(chatId);
    final peer = _peerHosting(chatId);
    if (peer != null) _openOnPeer(peer, chatId);
  }

  void unfollowChat(String chatId) {
    _desired.remove(chatId);
    // No unsubscribe message: the home side drops a subscription when the
    // mirror vanishes from its welcome round-trip, and an unwatched stream
    // costs nothing until a turn runs in it.
  }

  Future<Uint8List?> fetchResource(String chatId, String resource) async {
    final peer = _peerHosting(chatId);
    if (peer == null) return null;
    final id = "r${_resourceSeq++}";
    final transfer = _pendingResources[id] = _ResourceTransfer();
    try {
      await peer.send(SyncMessage.resourceRequest(
          id: id, chatId: chatId, resource: resource));
      return await transfer.completer.future
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
    } finally {
      _pendingResources.remove(id);
    }
  }

  _LivePeer? _peerHosting(String chatId) {
    final mirror = _mirrors[chatId];
    if (mirror == null) return null;
    return _live[mirror.peerId];
  }

  // ------------------------------------------------------------ dispatch

  /// Every arm of [SyncMessage] lands here, in arrival order per peer.
  /// Serving arms read the repository; mirror arms update [_mirrors] and
  /// notify whoever is watching. The control arms are Phase 3: declared on
  /// the wire, unimplemented here — a peer sending one gets nothing back,
  /// which a view-only mirror is the honest answer to for now.
  Future<void> _dispatch(_LivePeer peer, SyncMessage message) async {
    switch (message) {
      case SyncPing():
        await peer.send(const SyncMessage.pong());
      case SyncPong():
        peer.lastPong = DateTime.now();
      case SyncWelcome(:final chats):
        await _applyWelcome(peer, chats);
      case SyncChatsChanged(:final chats):
        await _applyWelcome(peer, chats);
      case SyncChatOpen(:final chatId, :final fromLine):
        await _serveOpen(peer, chatId, fromLine);
      case SyncChatSnapshot(
          :final chatId,
          :final state,
          :final meta,
          :final records,
          :final totalLines
        ):
        final existing = _mirrors[chatId];
        if (existing == null || existing.peerId != peer.deviceId) break;
        existing
          ..state = state
          ..meta = meta
          ..totalLines = totalLines;
        existing.records.addAll(records);
        _mirrorUpdates.add(chatId);
      case SyncRecordAppend(:final chatId, :final records):
        final existing = _mirrors[chatId];
        if (existing == null || existing.peerId != peer.deviceId) break;
        existing.records.addAll(records);
        existing.totalLines += records.length;
        _mirrorUpdates.add(chatId);
      case SyncStateDiff(:final chatId, :final state):
        final existing = _mirrors[chatId];
        if (existing == null || existing.peerId != peer.deviceId) break;
        existing.state = state;
        _mirrorUpdates.add(chatId);
      case SyncMetaPatch(:final chatId, :final meta):
        final existing = _mirrors[chatId];
        if (existing == null || existing.peerId != peer.deviceId) break;
        existing.meta = meta;
        _mirrorUpdates.add(chatId);
      case SyncChatDeleted(:final chatId):
        _dropMirror(peer.deviceId, chatId);
      case SyncChatMoved(:final chatId, :final project):
        final existing = _mirrors[chatId];
        if (existing == null || existing.peerId != peer.deviceId) break;
        existing.state =
            existing.state.copyWith(project: project);
        _mirrorUpdates.add(chatId);
      case SyncResourceRequest(:final id, :final chatId, :final resource):
        await _serveResource(peer, id, chatId, resource);
      case SyncResourceChunk(:final id, :final bytesB64, :final done):
        _collectResourceChunk(id, bytesB64, done);
      default:
        break;
    }
    _rebuildRemotes();
  }

  /// A fresh listing from the peer. Mirrors of this peer not in it go; those
  /// in it are added or refreshed — keeping records already held, so the
  /// re-opens below resume rather than restart. Then everything this device
  /// follows and still sees is asked for again, from where it got to.
  Future<void> _applyWelcome(_LivePeer peer, List<ChatState> chats) async {
    final listed = {for (final c in chats) c.id: c};
    for (final id in _mirrors.keys.toList()) {
      if (_mirrors[id]!.peerId == peer.deviceId && !listed.containsKey(id)) {
        _dropMirror(peer.deviceId, id);
      }
    }
    for (final state in chats) {
      final existing = _mirrors[state.id];
      if (existing != null && existing.peerId != peer.deviceId) continue;
      _mirrors[state.id] ??= MirrorChat(
        peerId: peer.deviceId,
        deviceName: peer.deviceName,
        state: state,
        meta: ChatMeta(),
        totalLines: 0,
      );
      final mirror = _mirrors[state.id]!;
      if (state.updatedAt.isAfter(mirror.state.updatedAt)) {
        mirror.state = state;
      }
    }
    for (final id in _desired) {
      if (listed.containsKey(id)) _openOnPeer(peer, id);
    }
  }

  void _openOnPeer(_LivePeer peer, String chatId) {
    unawaited(peer.send(SyncMessage.chatOpen(
      chatId: chatId,
      fromLine: _mirrors[chatId]?.records.length ?? 0,
    )));
  }

  void _dropMirror(String peerId, String chatId) {
    final mirror = _mirrors[chatId];
    if (mirror == null || mirror.peerId != peerId) return;
    _mirrors.remove(chatId);
    byteCache.drop(chatId);
    _mirrorUpdates.add(chatId);
  }

  // -------------------------------------------------------------- serving

  /// A peer wants to follow one of this device's chats. Unknown ids get an
  /// explicit deletion rather than silence — a mirror that opened a chat
  /// deleted moments ago must hear that it is gone.
  Future<void> _serveOpen(
      _LivePeer peer, String chatId, int fromLine) async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final chat = await repo.openChat(chatId);
      final meta = await repo.loadMeta(chatId);
      final records = await repo.readRecords(chatId);
      peer.subscriptions.add(chatId);
      await peer.send(SyncMessage.chatSnapshot(
        chatId: chatId,
        state: chat.state,
        meta: meta,
        records: fromLine < records.length
            ? records.sublist(fromLine)
            : const [],
        totalLines: records.length,
      ));
    } on StateError {
      peer.subscriptions.remove(chatId);
      await peer.send(SyncMessage.chatDeleted(chatId: chatId));
    }
  }

  /// Everything written through the repository, fanned out to whichever
  /// peers follow the chat it happened in. Deletions reach everyone: a peer
  /// holding a mirror of something gone must be told even if it never
  /// opened the chat's records yet.
  void _onRepoEvent(RepoEvent event) {
    switch (event) {
      case Appended(:final chatId, :final records):
        for (final peer in _live.values) {
          if (peer.subscriptions.contains(chatId)) {
            unawaited(peer.send(SyncMessage.recordAppend(
                chatId: chatId, records: records)));
          }
        }
      case StateChanged(:final state):
        for (final peer in _live.values) {
          if (peer.subscriptions.contains(state.id)) {
            unawaited(peer.send(SyncMessage.stateDiff(chatId: state.id, state: state)));
          }
        }
      case MetaChanged(:final chatId, :final meta):
        for (final peer in _live.values) {
          if (peer.subscriptions.contains(chatId)) {
            unawaited(peer.send(SyncMessage.metaPatch(chatId: chatId, meta: meta)));
          }
        }
      case Deleted(:final chatId):
        for (final peer in _live.values) {
          peer.subscriptions.remove(chatId);
          unawaited(peer.send(SyncMessage.chatDeleted(chatId: chatId)));
        }
      case Moved(:final chatId, :final project):
        for (final peer in _live.values) {
          if (peer.subscriptions.contains(chatId)) {
            unawaited(peer.send(SyncMessage.chatMoved(chatId: chatId, project: project)));
          }
        }
    }
  }

  // ------------------------------------------------------------ resources

  static const _chunkBytes = 48 * 1024;

  /// Streams an attachment to a subscribing peer, base64 inside control
  /// frames — correlation stays trivial and every frame rides the same AEAD
  /// as the rest of the traffic. Binary framing can come later without a
  /// protocol change: the type byte already separates the streams.
  Future<void> _serveResource(
      _LivePeer peer, String id, String chatId, String resource) async {
    Uint8List? bytes;
    if (peer.subscriptions.contains(chatId)) {
      bytes = await _repo?.readResource(chatId, resource);
    }
    if (bytes == null || bytes.isEmpty) {
      await peer.send(SyncMessage.resourceChunk(id: id, bytesB64: "", done: true));
      return;
    }
    for (var at = 0; at < bytes.length; at += _chunkBytes) {
      final end = at + _chunkBytes > bytes.length ? bytes.length : at + _chunkBytes;
      final last = end >= bytes.length;
      await peer.send(SyncMessage.resourceChunk(
        id: id,
        bytesB64: base64Encode(bytes.sublist(at, end)),
        done: last,
      ));
    }
  }

  void _collectResourceChunk(String id, String bytesB64, bool done) {
    final transfer = _pendingResources[id];
    if (transfer == null || transfer.completer.isCompleted) return;
    if (!done) {
      transfer.buffer.add(base64Decode(bytesB64));
      return;
    }
    transfer.buffer.add(base64Decode(bytesB64));
    final bytes = transfer.buffer.takeBytes();
    transfer.completer.complete(bytes.isEmpty ? null : Uint8List.fromList(bytes));
    _pendingResources.remove(id);
  }

  // ------------------------------------------------------------- presence

  void _ping() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 75));
    for (final peer in _live.values.toList()) {
      if (peer.lastPong.isBefore(cutoff)) {
        unawaited(peer.close());
        continue;
      }
      unawaited(peer.send(const SyncMessage.ping()));
    }
  }

  String _nameOf(PairedDevice? device, PeerIdentity peer) =>
      (device?.name.isNotEmpty ?? false) ? device!.name : peer.name;

  /// A live connection ended. The peer goes offline; its mirrors stay as
  /// stale snapshots — the page shows its banner and disables the composer,
  /// and a reconnect replaces the whole lot with fresh data.
  void _peerGone(String deviceId) {
    final live = _live.remove(deviceId);
    // Both directions: the chats this device served them, and the ones it
    // mirrors from them — a mirror's page has a banner to raise, and nothing
    // else tells it the snapshot has stopped moving.
    for (final chatId in {
      ...?live?.subscriptions,
      ..._mirrorsOf(deviceId),
    }) {
      _mirrorUpdates.add(chatId);
    }
    _setStatus(deviceId,
        name: live?.deviceName ?? deviceId, status: PeerStatus.offline);
    _rebuildRemotes();
  }

  Iterable<String> _mirrorsOf(String deviceId) => _mirrors.entries
      .where((e) => e.value.peerId == deviceId)
      .map((e) => e.key)
      .toList();

  void _rebuildRemotes() {
    remotes.value = [
      for (final mirror in _mirrors.values)
        RemoteChatEntry(
          chatId: mirror.state.id,
          deviceId: mirror.peerId,
          deviceName: mirror.deviceName,
          state: mirror.state,
          online: _live.containsKey(mirror.peerId),
        ),
    ];
  }

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
    _pingTimer?.cancel();
    await _changesSub?.cancel();
    // Over a copy: closing a peer takes it back out of the map.
    for (final peer in _live.values.toList()) {
      await peer.close();
    }
    _live.clear();
    _mirrors.clear();
    byteCache.dispose();
    _desired.clear();
    remotes.value = const [];
    await _mirrorUpdates.close();
    for (final transfer in _pendingResources.values) {
      if (!transfer.completer.isCompleted) transfer.completer.complete(null);
    }
    _pendingResources.clear();
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
    // Everything of theirs goes with them. `_refreshPeers` only fills gaps
    // from the registry, so the row and the mirrors have to be taken out by
    // hand or an unpaired device stays listed, and online, until a restart.
    for (final chatId in _mirrorsOf(deviceId)) {
      _dropMirror(deviceId, chatId);
    }
    peers.value = {...peers.value}..remove(deviceId);
    _rebuildRemotes();
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
        "username": ?_settings().turnUsername,
        "credential": ?_settings().turnPassword,
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

  /// Tests drive the shared tail directly: a loopback [ByteChannel] stands in
  /// for the data channel, so everything from the handshake up is exercised
  /// with no transport, offer, or signaling underneath.
  @visibleForTesting
  Future<void> establishForTest({
    required ByteChannel link,
    required bool weOffered,
    required String psk,
    String? knownDeviceId,
  }) {
    // Every real route opens the pairing card before the handshake; without
    // one the codes-matched gate has nowhere to ask and never resolves.
    if (knownDeviceId == null) pairing.value = const PairingActivity();
    return _establish(
      link: link,
      weOffered: weOffered,
      psk: psk,
      knownDeviceId: knownDeviceId,
      onFailed: () async {},
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
    required Future<void> Function() onFailed,
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

      // The peer exists — and starts pumping — before anything below awaits.
      // The channel's streams are broadcast, so a message arriving while
      // nobody listens is dropped rather than buffered; everything either
      // side sends from here on (welcome first) must already have its reader.
      final deviceId = peer.id;
      final peerDevice = await registry.byId(deviceId);
      final live = _LivePeer(channel,
          deviceId: deviceId,
          deviceName: _nameOf(peerDevice, peer),
          onClose: () => _peerGone(deviceId));
      live.handle = (message) => _dispatch(live, message);
      live.pump = channel.jsonIncoming.listen(
        (json) {
          try {
            live.enqueue(SyncMessage.fromJson(json));
          } catch (_) {
            // A frame that does not parse is a broken peer; drop the link
            // rather than guess at what it meant.
            unawaited(live.close());
          }
        },
        onError: (_) => unawaited(live.close()),
        onDone: () => unawaited(live.close()),
      );

      var device = peerDevice;
      if (device == null) {
        device = PairedDevice(
          id: deviceId,
          name: live.deviceName,
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
      _live[deviceId] = live;
      _setStatus(deviceId,
          name: device.name, status: PeerStatus.online);

      // What this device serves. The mirror side answers this with
      // chatOpens for whatever it follows.
      final repo = _repo;
      if (repo != null) {
        final chats = await repo.listChats();
        live.send(SyncMessage.welcome(chats: chats));
      }

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
  _LivePeer(this.channel,
      {required this.deviceId,
      required this.deviceName,
      required this._onClose});

  final SecureChannel channel;
  final String deviceId;
  final String deviceName;
  final void Function() _onClose;
  bool _closed = false;

  DateTime lastPong = DateTime.now();

  /// This device's chat ids the peer is following. Only subscribers get
  /// record and state pushes.
  final subscriptions = <String>{};

  StreamSubscription<Map<String, dynamic>>? pump;

  /// Handlers await disk I/O, so messages are chained through this to keep
  /// their arrival order — a snapshot must land before the appends that
  /// follow it.
  Future<void> _queue = Future.value();

  void enqueue(SyncMessage message) {
    if (_closed) return;
    _queue = _queue.then((_) => handle?.call(message)).catchError((_) {});
  }

  /// Set once the peer exists; reads [SyncHub._dispatch].
  void Function(SyncMessage message)? handle;

  Future<void> send(SyncMessage message) {
    if (_closed) return Future.value();
    return channel.sendJson(message.toJson());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await pump?.cancel();
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

/// One resource transfer in flight: chunks accumulate until `done`.
class _ResourceTransfer {
  final completer = Completer<Uint8List?>();
  final buffer = BytesBuilder(copy: false);
}
