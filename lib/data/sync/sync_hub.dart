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
import "../../domain/models.dart" show ChatState, ToolApproval;
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../domain/sync/lan_signaling.dart";
import "../../domain/sync/protocol.dart";
import "../../domain/sync/relay_signaling.dart";
import "channel.dart";
import "framing.dart";
import "peers.dart";

// The peer registry's types are part of what a `SyncHub` hands out.
export "peers.dart" show PeerState, PeerStatus;
import "handshake.dart";
import "rtc_channel.dart";
import "signaling/lan_signaler.dart";
import "signaling/pairing_payload.dart";
import "signaling/relay_signaler.dart";
import "sync_byte_cache.dart";
import "../../core/log.dart";

export "signaling/pairing_payload.dart"
    show PairingOffer, generatePairingCode, generatePsk;

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
  });

  final String peerId;


  /// The home device's name, as its hello carried it — what the sidebar's
  /// Remotes rows show under the title.
  final String deviceName;
  ChatState state;
  ChatMeta meta;
  final List<ChatRecord> records = [];

  /// Which device the home end says holds the chat, or null for nobody.
  /// Never assumed locally: taking control is the home device's answer, so
  /// a request that lost a race reads as somebody else's id rather than as
  /// this device's own.
  String? controlHolder;

  /// The turn, as the home device last reported it. None of this is in the
  /// log — a running turn, a command waiting to be allowed, a question
  /// waiting to be answered — so it arrives as its own message.
  bool running = false;
  List<ToolApproval> approvals = const [];
  List<SyncAsk> asks = const [];
  String? status;
  String? retry;

  @override
  String toString() => "MirrorChat(${state.id}, ${records.length} records)";
}

/// What a chat's home device does when the mirror holding it drives a turn.
/// Registered on the [SyncHub] by the container, because running a turn is
/// `ChatController`'s and the hub has no way to reach one — the same reason
/// the repository arrives through [SyncHub.attach].
abstract interface class RemoteTurns {
  void prompt(String chatId, String text);
  void resume(String chatId);
  void abort(String chatId);
  void approve(String chatId, String approvalId, bool allow);
  void answer(String chatId, String requestId, List<String?> answers);
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

  /// By value, so a rebuild that produced the same rows is not a change. The
  /// list is rebuilt from every message that touches a mirror, and without
  /// this each ping-sized nudge repainted the sidebar and the open page.
  @override
  bool operator ==(Object other) =>
      other is RemoteChatEntry &&
      other.chatId == chatId &&
      other.deviceId == deviceId &&
      other.deviceName == deviceName &&
      other.online == online &&
      other.state == state;

  @override
  int get hashCode => Object.hash(chatId, deviceId, deviceName, online, state);
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
    this._hostname,
    http.Client? client,
    RelayDial? relayDial,
  })  : _lanFactory = lanSignaling,
        _relayDial = relayDial ?? RelaySignaler.connect,
        _client = client ?? http.Client();

  final SyncIdentity identity;
  final DeviceRegistry registry;

  final AppSettings Function() _settings;

  /// What the machine calls itself, where it has a name — the default device
  /// name before the user picks one. Passed in rather than read here: it is
  /// `dart:io`'s, and a browser has none.
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
  late final SyncPeers _peers = SyncPeers(registry);

  /// Every paired device with how it stands. The UI's whole view of sync.
  ValueNotifier<Map<String, PeerState>> get peers => _peers.states;

  /// The pairing happening right now, if any.
  final pairing = ValueNotifier<PairingActivity?>(null);

  // ------------------------------------------------------------- mirroring

  ChatRepository? _repo;
  StreamSubscription<RepoEvent>? _changesSub;

  /// The peer's chats this device mirrors, by chat id. Survives a disconnect
  /// as a stale snapshot; a reconnect replaces it wholesale with fresh data.
  final _mirrors = <String, MirrorChat>{};

  /// Chat ids being followed across reconnects — what [followChat] added and
  /// [unfollowChat] has not removed. On every welcome these are re-opened
  /// from where the mirror already is.
  final _desired = <String>{};

  /// Chats of this device somebody else is driving: chat id to the device id
  /// holding it. One holder at a time, and the home device is never in it —
  /// this device typing is not a lock, it is the absence of one.
  final _control = <String, String>{};

  /// Set by the container once there is a way to run a turn. Null until then,
  /// which is every test that is only about the wire.
  RemoteTurns? remoteTurns;

  /// Mirrored attachments, held only as long as the mirror is. Owned here
  /// rather than beside the page that shows them so that a mirror going
  /// takes its megabytes with it.
  final byteCache = SyncByteCache();

  final _mirrorUpdates = StreamController<String>.broadcast();

  Stream<String> get mirrorUpdates => _mirrorUpdates.stream;

  /// The Remotes section of the sidebar: one entry per mirrored chat, flat,
  /// rebuilt whenever anything under it moves.
  final remotes = ValueNotifier<List<RemoteChatEntry>>(const []);

  /// Chats of this device somebody else is driving, by the name of the device
  /// driving them — what the local chat page says over a conversation being
  /// typed into from elsewhere. Names rather than ids: it is read out.
  final drivenChats = ValueNotifier<Map<String, String>>(const {});

  /// Chats of this device that some peer is watching. The home end keeps a
  /// controller open for each — that is what makes a turn's progress, and the
  /// approvals and questions it stops on, visible at the other end, none of
  /// which is in the log.
  ValueNotifier<Set<String>> get servedChats => _peers.servedChats;


  MirrorChat? mirror(String chatId) => _mirrors[chatId];

  /// Which device is driving one of *this* device's chats, or null. What the
  /// local chat page reads to say it is being typed in from elsewhere.
  String? heldBy(String chatId) => _control[chatId];

  /// Whether this device holds a mirrored chat — the home device's answer,
  /// never a local guess.
  bool holdsControl(String chatId) =>
      _mirrors[chatId]?.controlHolder == identity.id;

  /// Whether the connection to [chatId]'s home device is up. False for a
  /// stale snapshot: the page disables the composer and shows its banner.
  bool isChatOnline(String chatId) =>
      _peers.hasLive(_mirrors[chatId]?.peerId);

  int _resourceSeq = 0;
  final _pendingResources = <String, _ResourceTransfer>{};

  /// Whether the hub has been given the repository the serving side is built
  /// on. False is a device that pairs, and then serves nothing at all — which
  /// is what shipped, because `attach` was called by every test's harness and
  /// by nothing in the app.
  @visibleForTesting
  bool get isServing => _repo != null;

  /// The repository arrives after construction — the container that holds it
  /// does not exist yet when [SyncHub] is built. Serving-side everything is
  /// inert until this is called.
  void attach(ChatRepository repo) {
    if (_repo != null) return;
    _repo = repo;
    _changesSub = repo.changes.listen(_onRepoEvent);
    _peers.watchLiveness();
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

  /// An attachment of a mirrored chat: from the cache, or over the wire and
  /// into it. The policy lives beside the cache rather than at the page that
  /// draws the image, so a second caller cannot get the three steps wrong or
  /// quietly bypass them.
  Future<Uint8List?> resourceBytes(String chatId, String resource) async {
    final cached = byteCache.get(chatId, resource);
    if (cached != null) return cached;
    final bytes = await fetchResource(chatId, resource);
    if (bytes != null) byteCache.put(chatId, resource, bytes);
    return bytes;
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

  LivePeer? _peerHosting(String chatId) {
    final mirror = _mirrors[chatId];
    if (mirror == null) return null;
    return _peers[mirror.peerId];
  }

  // ------------------------------------------------------------ dispatch

  /// Every arm of [SyncMessage] lands here, in arrival order per peer.
  /// Serving arms read the repository; mirror arms update [_mirrors] and
  /// notify whoever is watching. The control arms are Phase 3: declared on
  /// the wire, unimplemented here — a peer sending one gets nothing back,
  /// which a view-only mirror is the honest answer to for now.
  Future<void> _dispatch(LivePeer peer, SyncMessage message) async {
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
      case SyncChatSnapshot(:final chatId, :final state, :final meta):
        // The head only. Records already held are kept: a resume asks from
        // the line this mirror got to, so what follows is the tail.
        _onMirror(peer, chatId, (mirror) => mirror
          ..state = state
          ..meta = meta);
      case SyncRecordAppend(:final chatId, :final records):
        _onMirror(peer, chatId, (mirror) => mirror.records.addAll(records));
      case SyncStateDiff(:final chatId, :final state):
        _onMirror(peer, chatId, (mirror) => mirror.state = state);
      case SyncMetaPatch(:final chatId, :final meta):
        _onMirror(peer, chatId, (mirror) => mirror.meta = meta);
      case SyncChatDeleted(:final chatId):
        _dropMirror(peer.deviceId, chatId);
      case SyncChatMoved(:final chatId, :final project):
        _onMirror(peer, chatId,
            (mirror) => mirror.state = mirror.state.copyWith(project: project));
      case SyncResourceRequest(:final id, :final chatId, :final resource):
        await _serveResource(peer, id, chatId, resource);
      case SyncResourceChunk(:final id, :final bytesB64, :final done):
        _collectResourceChunk(id, bytesB64, done);

      // -- serving: somebody else driving one of this device's chats
      case SyncControlRequest(:final chatId):
        await _serveControlRequest(peer, chatId);
      case SyncControlRelease(:final chatId):
        await _serveControlRelease(peer, chatId);
      case SyncPromptSend(:final chatId, :final text):
        if (_holds(peer, chatId)) remoteTurns?.prompt(chatId, text);
      case SyncTurnResume(:final chatId):
        if (_holds(peer, chatId)) remoteTurns?.resume(chatId);
      case SyncTurnAbort(:final chatId):
        if (_holds(peer, chatId)) remoteTurns?.abort(chatId);
      case SyncApprovalRespond(:final chatId, :final approvalId, :final allow):
        if (_holds(peer, chatId)) {
          remoteTurns?.approve(chatId, approvalId, allow);
        }
      case SyncQuestionsRespond(
          :final chatId,
          :final requestId,
          :final answers
        ):
        if (_holds(peer, chatId)) {
          remoteTurns?.answer(chatId, requestId, answers);
        }

      // -- mirroring: what the home device says about a chat we follow
      case SyncControlState(:final chatId, :final holder):
        _onMirror(peer, chatId, (mirror) => mirror.controlHolder = holder);
      case SyncControlGrant(:final chatId, :final granted):
        // The state message that follows is what actually moves the holder;
        // a refusal is worth nothing more than dropping the asking flag.
        if (!granted) _requesting.remove(chatId);
        _touch(chatId);
      case SyncTurnState(
          :final chatId,
          :final running,
          :final approvals,
          :final asks,
          :final status,
          :final retry
        ):
        _onMirror(
            peer,
            chatId,
            (mirror) => mirror
              ..running = running
              ..approvals = approvals
              ..asks = asks
              ..status = status
              ..retry = retry);
    }
  }

  /// Apply [change] to the mirror [peer] is talking about, and tell whoever
  /// is watching. The ownership check is here rather than in each arm: a peer
  /// may only speak about the chats it is the home device for, and an arm
  /// that forgot the check — or the notify — would be silently wrong.
  void _onMirror(
      LivePeer peer, String chatId, void Function(MirrorChat mirror) change) {
    final mirror = _mirrors[chatId];
    if (mirror == null || mirror.peerId != peer.deviceId) return;
    change(mirror);
    _rebuildRemotes();
    _touch(chatId);
  }

  final _touched = <String>{};

  /// Says a mirror moved, once per burst. Whoever listens rebuilds the whole
  /// conversation from its records, so a snapshot arriving as a dozen pages
  /// would replay the log a dozen times, each one longer than the last — and
  /// a turn's records land in bursts too. Collapsed on a microtask, the pages
  /// of one snapshot are one projection.
  void _touch(String chatId) {
    if (!_touched.add(chatId)) return;
    scheduleMicrotask(() {
      _touched.remove(chatId);
      if (!_mirrorUpdates.isClosed) _mirrorUpdates.add(chatId);
    });
  }

  /// Whether [peer] is the device this chat's control was granted to. Every
  /// arm that drives a turn goes through it: a peer that never asked, or that
  /// lost the race, must not be able to type into somebody's conversation.
  bool _holds(LivePeer peer, String chatId) =>
      _control[chatId] == peer.deviceId;

  /// A fresh listing from the peer. Mirrors of this peer not in it go; those
  /// in it are added or refreshed — keeping records already held, so the
  /// re-opens below resume rather than restart. Then everything this device
  /// follows and still sees is asked for again, from where it got to.
  Future<void> _applyWelcome(LivePeer peer, List<ChatState> chats) async {
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
      );
      final mirror = _mirrors[state.id]!;
      if (state.updatedAt.isAfter(mirror.state.updatedAt)) {
        mirror.state = state;
      }
    }
    for (final id in _desired) {
      if (listed.containsKey(id)) _openOnPeer(peer, id);
    }
    _rebuildRemotes();
  }

  void _openOnPeer(LivePeer peer, String chatId) {
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
    _requesting.remove(chatId);
    _rebuildRemotes();
    _touch(chatId);
  }

  // -------------------------------------------------------------- serving

  /// A peer wants to follow one of this device's chats. Unknown ids get an
  /// explicit deletion rather than silence — a mirror that opened a chat
  /// deleted moments ago must hear that it is gone.
  Future<void> _serveOpen(
      LivePeer peer, String chatId, int fromLine) async {
    final repo = _repo;
    if (repo == null) return;
    // Three independent reads, and the state one rather than `openChat`:
    // that replays the whole log to build a `Chat` this throws away, having
    // just read the same file again for the records it actually sends.
    final (state, meta, records) = await (
      repo.loadState(chatId),
      repo.loadMeta(chatId),
      repo.readRecords(chatId),
    ).wait;
    try {
      if (state == null) throw StateError("no chat $chatId");
      peer.subscriptions.add(chatId);
      // Who holds it goes with the snapshot: a mirror that reconnects mid-
      // turn must not draw a Take control button for a chat it already has.
      await peer.send(
          SyncMessage.controlState(chatId: chatId, holder: _control[chatId]));
      await peer.send(SyncMessage.chatSnapshot(
        chatId: chatId,
        state: state,
        meta: meta,
      ));
      await _sendRecords(
          peer,
          chatId,
          fromLine < records.length
              ? records.sublist(fromLine)
              : const []);
    } on StateError {
      logFailure("sync", "asked for chat $chatId, which is not here");
      peer.subscriptions.remove(chatId);
      await peer.send(SyncMessage.chatDeleted(chatId: chatId));
    }
    _peers.refreshServed();
  }

  /// Everything written through the repository, fanned out to whichever
  /// peers follow the chat it happened in. Deletions reach everyone: a peer
  /// holding a mirror of something gone must be told even if it never
  /// opened the chat's records yet.
  void _onRepoEvent(RepoEvent event) {
    switch (event) {
      case Appended(:final chatId, :final records):
        for (final peer in _peers.live) {
          if (peer.subscriptions.contains(chatId)) {
            unawaited(_sendRecords(peer, chatId, records));
          }
        }
      case StateChanged(:final state):
        _peers.toSubscribers(
            state.id, SyncMessage.stateDiff(chatId: state.id, state: state));
        // A chat nobody has been told about is a new one — its first save.
        // The list goes out again so it appears in a mirror's Remotes rather
        // than only after the next reconnect.
        if (!_announced.contains(state.id)) unawaited(_announceChats());
      case MetaChanged(:final chatId, :final meta):
        _peers.toSubscribers(
            chatId, SyncMessage.metaPatch(chatId: chatId, meta: meta));
      case Moved(:final chatId, :final project):
        _peers.toSubscribers(
            chatId, SyncMessage.chatMoved(chatId: chatId, project: project));
      case Deleted(:final chatId):
        // To everyone, not only subscribers: a peer holding a mirror of
        // something gone has to be told even if it never opened the records.
        for (final peer in _peers.live) {
          peer.subscriptions.remove(chatId);
          unawaited(peer.send(SyncMessage.chatDeleted(chatId: chatId)));
        }
        _control.remove(chatId);
        _announced.remove(chatId);
        _refreshDriven();
        _peers.refreshServed();
    }
  }

  /// Which of this device's chats the peers have been told about. Only so a
  /// chat appearing can be noticed: the list is small, but reading it off
  /// disk on every `saveState` of every turn would not be.
  var _announced = <String>{};

  Future<void> _announceChats() async {
    final repo = _repo;
    if (repo == null || _peers.isEmpty) return;
    final chats = await repo.listChats();
    _announced = {for (final chat in chats) chat.id};
    final message = SyncMessage.chatsChanged(chats: chats);
    for (final peer in _peers.live) {
      unawaited(peer.send(message));
    }
  }

  // -------------------------------------------------------------- control

  /// One holder at a time, first asker wins. Re-asking while already holding
  /// it is granted rather than refused: a mirror that reconnected does not
  /// know it never lost the lock.
  Future<void> _serveControlRequest(LivePeer peer, String chatId) async {
    final held = _control[chatId];
    final granted = held == null || held == peer.deviceId;
    if (granted) {
      _control[chatId] = peer.deviceId;
    }
    await peer.send(
        SyncMessage.controlGrant(chatId: chatId, granted: granted));
    _announceControl(chatId);
  }

  Future<void> _serveControlRelease(LivePeer peer, String chatId) async {
    if (_control[chatId] != peer.deviceId) return;
    _control.remove(chatId);
    _announceControl(chatId);
  }

  /// Everyone watching the chat hears who holds it, not only the asker — a
  /// second mirror has to see that the first one took it.
  void _announceControl(String chatId) {
    _refreshDriven();
    _peers.toSubscribers(chatId,
        SyncMessage.controlState(chatId: chatId, holder: _control[chatId]));
  }

  void _refreshDriven() => drivenChats.value = {
        for (final entry in _control.entries)
          entry.key: _peers[entry.value]?.deviceName ?? entry.value,
      };

  /// The turn as this device's own controller has it, on its way to whoever
  /// is watching. Called by the container on every change: none of this is in
  /// the log, so nothing else would carry it.
  void publishTurn(
    String chatId, {
    required bool running,
    List<ToolApproval> approvals = const [],
    List<SyncAsk> asks = const [],
    String? status,
    String? retry,
  }) {
    _peers.toSubscribers(
        chatId,
        SyncMessage.turnState(
          chatId: chatId,
          running: running,
          approvals: approvals,
          asks: asks,
          status: status,
          retry: retry,
        ));
  }

  /// Chats this device holds on a peer, asked for and not yet answered. Only
  /// so a button can say "asking"; the holder itself is the home device's.
  final _requesting = <String>{};

  bool isRequestingControl(String chatId) => _requesting.contains(chatId);

  Future<void> requestControl(String chatId) async {
    final peer = _peerHosting(chatId);
    if (peer == null) return;
    _requesting.add(chatId);
    _touch(chatId);
    await peer.send(SyncMessage.controlRequest(chatId: chatId));
  }

  Future<void> releaseControl(String chatId) async {
    _requesting.remove(chatId);
    final peer = _peerHosting(chatId);
    if (peer == null) return;
    await peer.send(SyncMessage.controlRelease(chatId: chatId));
  }

  /// Drive a turn on the chat's home device. Every one of these is refused
  /// there unless this device holds the chat, so the check here is about not
  /// sending into the void rather than about permission.
  Future<void> sendRemotePrompt(String chatId, String text) =>
      _drive(chatId, SyncMessage.promptSend(chatId: chatId, text: text));

  Future<void> resumeRemote(String chatId) =>
      _drive(chatId, SyncMessage.turnResume(chatId: chatId));

  Future<void> abortRemote(String chatId) =>
      _drive(chatId, SyncMessage.turnAbort(chatId: chatId));

  Future<void> respondRemoteApproval(
          String chatId, String approvalId, bool allow) =>
      _drive(
          chatId,
          SyncMessage.approvalRespond(
              chatId: chatId, approvalId: approvalId, allow: allow));

  Future<void> answerRemoteQuestions(
          String chatId, String requestId, List<String?> answers) =>
      _drive(
          chatId,
          SyncMessage.questionsRespond(
              chatId: chatId, requestId: requestId, answers: answers));

  Future<void> _drive(String chatId, SyncMessage message) async {
    if (!holdsControl(chatId)) return;
    await _peerHosting(chatId)?.send(message);
  }

  /// Straight to the chat's home device, past the guard in [_drive]. That
  /// guard is about not shouting into the void; what refuses a peer holding
  /// nothing is the home device, and this is how a test reaches it.
  @visibleForTesting
  Future<void> sendForTest(String chatId, SyncMessage message) async =>
      _peerHosting(chatId)?.send(message);

  /// Records in pages small enough for one message. A data channel refuses a
  /// message past its negotiated maximum, and a conversation of any length is
  /// far past it — half a megabyte of `conv.jsonl` is an ordinary size, and
  /// sending that whole was a mirror that opened empty and said nothing about
  /// why. Measured rather than counted: one record can be a whole file.
  /// What one message may carry. A data channel refuses more, and both the
  /// things that can exceed it — a chat's log, an attachment — are paged
  /// against it. Records are measured as encoded JSON; resource chunks are
  /// measured as source bytes, which base64 expands by a third, so they get
  /// their own smaller bound rather than sharing this one and overshooting.
  static const _messageBytes = 48 * 1024;
  static const _chunkBytes = 32 * 1024;

  Future<void> _sendRecords(
      LivePeer peer, String chatId, List<ChatRecord> records) async {
    var page = <ChatRecord>[];
    var bytes = 0;
    Future<void> flush() async {
      if (page.isEmpty) return;
      await peer.send(SyncMessage.recordAppend(chatId: chatId, records: page));
      page = [];
      bytes = 0;
    }

    for (final record in records) {
      // Encoded to be measured and then thrown away: `sendJson` encodes the
      // page again below. Reusing it would mean carrying the strings through
      // `SyncMessage`, or the store handing back the line lengths it already
      // split on — neither worth it for one extra encode per chat opened.
      final size = jsonEncode(record.toJson()).length;
      if (bytes + size > _messageBytes) await flush();
      page.add(record);
      bytes += size;
    }
    await flush();
  }

  // ------------------------------------------------------------ resources


  /// Streams an attachment to a subscribing peer, base64 inside control
  /// frames — correlation stays trivial and every frame rides the same AEAD
  /// as the rest of the traffic. Binary framing can come later without a
  /// protocol change: the type byte already separates the streams.
  Future<void> _serveResource(
      LivePeer peer, String id, String chatId, String resource) async {
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
        // A view rather than a copy: the chunk is encoded straight out of it.
        bytesB64: base64Encode(Uint8List.sublistView(bytes, at, end)),
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
    // `takeBytes` already hands back a Uint8List of exactly the right length.
    final bytes = transfer.buffer.takeBytes();
    transfer.completer.complete(bytes.isEmpty ? null : bytes);
    _pendingResources.remove(id);
  }

  // ------------------------------------------------------------- presence

  String _nameOf(PairedDevice? device, PeerIdentity peer) =>
      (device?.name.isNotEmpty ?? false) ? device!.name : peer.name;

  /// A live connection ended. The peer goes offline; its mirrors stay as
  /// stale snapshots — the page shows its banner and disables the composer,
  /// and a reconnect replaces the whole lot with fresh data.
  void _peerGone(String deviceId) {
    final live = _peers.remove(deviceId);
    // A lock outliving the connection that took it would leave the chat
    // unusable at both ends until one side restarted.
    for (final entry in _control.entries.toList()) {
      if (entry.value != deviceId) continue;
      _control.remove(entry.key);
      _announceControl(entry.key);
    }
    // Both directions: the chats this device served them, and the ones it
    // mirrors from them — a mirror's page has a banner to raise, and nothing
    // else tells it the snapshot has stopped moving.
    for (final chatId in {
      ...?live?.subscriptions,
      ..._mirrorsOf(deviceId),
    }) {
      _touch(chatId);
    }
    _peers.setStatus(deviceId,
        name: live?.deviceName ?? deviceId, status: PeerStatus.offline);
    _peers.refreshServed();
    _rebuildRemotes();
  }

  Iterable<String> _mirrorsOf(String deviceId) => _mirrors.entries
      .where((e) => e.value.peerId == deviceId)
      .map((e) => e.key)
      .toList();

  void _rebuildRemotes() {
    final next = [
      for (final mirror in _mirrors.values)
        RemoteChatEntry(
          chatId: mirror.state.id,
          deviceId: mirror.peerId,
          deviceName: mirror.deviceName,
          state: mirror.state,
          online: _peers.hasLive(mirror.peerId),
        ),
    ];
    if (!listEquals(next, remotes.value)) remotes.value = next;
  }

  // ------------------------------------------------------------ lifecycle

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
    // Before the early return below: a web build listens for nothing and a
    // desktop with no pairings starts no server, and both still have a list
    // of paired devices to draw.
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
    await _changesSub?.cancel();
    // Before the mirror state below: closing a peer runs [_peerGone], which
    // reads it. [_mirrorUpdates] closes after both, and [_touch]'s microtask
    // is why that one is guarded rather than ordered.
    await _peers.dispose();
    _mirrors.clear();
    byteCache.dispose();
    _control.clear();
    _requesting.clear();
    drivenChats.value = const {};
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
  Future<PairingActivity> startPairingWindow() async {
    cancelPairingWindow();
    final server = _server;
    final lanAvailable = server != null && !kIsWeb;
    final relayUrl = _settings().syncRelayUrl ?? "";
    if (!lanAvailable && relayUrl.isEmpty) throw SignalingException(noRoute);

    final psk = generatePsk();
    String? qr;
    String? code;
    if (lanAvailable) {
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
    final activity =
        PairingActivity(qr: qr, code: code, stage: PairingStage.connecting);
    pairing.value = activity;
    return activity;
  }

  /// Why there is no window to open. A browser has no socket to bind, so it
  /// can only ever join — which makes the relay the one thing missing rather
  /// than one of two.
  static String get noRoute => kIsWeb
      ? "A browser cannot listen for a pairing. Set a relay URL above, or "
          "use Manual invite and paste the reply back."
      : "No way to be found: this build has no local network signaling and "
          "no relay URL is set.";

  void cancelPairingWindow() {
    _windowPsk = null;
    _confirmation?.complete(false);
    _confirmation = null;
    _relayWindow?.cancel();
    _relayWindow = null;
    unawaited(_relaySocket?.close());
    _relaySocket = null;
    _server?.disarm();
    // The offers subscription is *not* cancelled: it answers reconnects too,
    // and every pairing ends by closing its window. Cancelled here, the first
    // successful pair was also the last time anything answered a dial.
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
  Future<void> _completeManualPairing(PairingOffer answer) async {
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
    _peers.setStatus(deviceId, name: device.name, status: PeerStatus.connecting);
    final token = RelaySignaler.roomFor(secret);

    Object? failure;
    final address = device.lastAddress;
    if (address != null && address.contains(":")) {
      final at = address.lastIndexOf(":");
      try {
        await _dialOverLan(
          hosts: [address.substring(0, at)],
          // The port it was last seen on, then the one it would normally be
          // on: a device that restarted onto an ephemeral port is at neither,
          // but one that simply restarted is at the second.
          ports: {int.parse(address.substring(at + 1)), preferredSignalingPort}
              .toList(),
          token: token,
          psk: secret,
          knownDeviceId: deviceId,
          address: address,
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

  /// Unpairs: drops the record, its secret, and any live connection. The
  /// other device keeps ours until someone revokes there too.
  Future<void> revoke(String deviceId) async {
    await _peers.remove(deviceId)?.close();
    // Before the registry read below loses the secret: the token derived from
    // it is what admits this device, and clearing everything *except* that
    // left a revoked device still dialling in and still being answered, until
    // something restarted.
    final secret = await registry.pairingSecret(deviceId);
    if (secret != null) _forgetReconnect(secret);
    await registry.remove(deviceId);
    // Everything of theirs goes with them. `_refreshPeers` only fills gaps
    // from the registry, so the row and the mirrors have to be taken out by
    // hand or an unpaired device stays listed, and online, until a restart.
    for (final chatId in _mirrorsOf(deviceId)) {
      _dropMirror(deviceId, chatId);
    }
    _peers.forget(deviceId);
    _rebuildRemotes();
    unawaited(_peers.refresh());
  }

  /// What the other device files this one under.
  String get deviceName => _settings().deviceName ?? defaultDeviceName;

  /// What it would be called with nothing set — the machine's own name where
  /// there is one, since that is what its owner already calls it, and the
  /// key's first characters otherwise, which at least cannot collide. Its own
  /// getter because the Sync page's field wants exactly this: the hint has to
  /// go on saying what the default is after a name has been typed over it.
  String get defaultDeviceName =>
      _hostname ?? "Entoli ${identity.fingerprint.substring(0, 5)}";

  /// Where a peer could dial this device back, or null where it is not
  /// listening — a browser never is.
  Future<String?> _dialbackAddress() async {
    final server = _server;
    if (server == null || kIsWeb) return null;
    final port = server.port ?? await server.start();
    final addresses = await server.addresses();
    return addresses.isEmpty ? null : "${addresses.first}:$port";
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
        "credential": ?_settings().turnPassword,
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
            onFailed: () => link!.close(),
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
  @visibleForTesting
  bool admitsReconnect(String psk) =>
      _reconnects.containsKey(RelaySignaler.roomFor(psk));

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
    try {
      await _dialOverLan(
        hosts: payload.hosts,
        ports: [payload.port],
        code: payload.code,
        psk: payload.psk,
        address: "${payload.hosts.first}:${payload.port}",
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
    required List<String> hosts,
    required List<int> ports,
    required String psk,
    String code = "",
    String token = "",
    String? knownDeviceId,
    String? address,
  }) async {
    final link = await RtcLink.create(iceServers: iceServers());
    try {
      final sdp = await link.offer();
      final signaler = LanSignaler(client: _client);
      final String answer;
      try {
        answer = await signaler.exchange(
            hosts: hosts, ports: ports, code: code, token: token, offerSdp: sdp);
      } finally {
        signaler.close();
      }
      await link.acceptAnswer(answer);
      await _establish(
        link: await link.open(),
        weOffered: true,
        psk: psk,
        knownDeviceId: knownDeviceId,
        address: address,
        onFailed: () => link.close(),
      );
    } catch (_) {
      await link.close();
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

      // The codes are compared before anything is read or sent. The other
      // side answers the moment *its* human has confirmed, which may be well
      // before ours has — and what it sends is held by the channel until the
      // reader below attaches, so there is nothing to be careful about here.
      // It cost four bugs to stop needing that care; see the framing.
      if (await _sasGate(handshake.sas!, isNew: knownDeviceId == null) ==
          false) {
        throw const HandshakeException("the codes did not match");
      }

      final deviceId = peer.id;
      final peerDevice = await registry.byId(deviceId);
      final live = LivePeer(channel,
          deviceId: deviceId,
          deviceName: _nameOf(peerDevice, peer),
          onClose: () => _peerGone(deviceId));
      final hello = Completer<Map<String, dynamic>>();
      live.handle = (message) => _dispatch(live, message);
      live.pump = channel.jsonIncoming.listen(
        (json) {
          // The hello is not a [SyncMessage]: it is the version check either
          // side runs before agreeing to speak the protocol at all.
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
        "proto": SyncIdentity.protocolVersion,
        "id": identity.id,
        "name": deviceName,
        // Where this device can be dialled back, if it listens at all. Only
        // the side that dialled knows the other's address otherwise, so only
        // that side could ever reconnect — the other one had no route and
        // said so.
        "addr": ?await _dialbackAddress(),
      });
      final reply = await hello.future.timeout(const Duration(seconds: 15));
      if (reply["proto"] != SyncIdentity.protocolVersion) {
        throw HandshakeException(
            "the other device runs protocol ${reply["proto"]}");
      }

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
      // The address it gave is as good as the one we dialled: on the side
      // that was dialled, it is the only one there is.
      await registry.markSeen(deviceId,
          address: address ?? reply["addr"] as String?);

      _peers.adopt(live);
      _peers.setStatus(deviceId,
          name: device.name, status: PeerStatus.online);

      // What this device serves. The mirror side answers this with
      // chatOpens for whatever it follows.
      final repo = _repo;
      if (repo != null) {
        final chats = await repo.listChats();
        _announced = {for (final chat in chats) chat.id};
        live.send(SyncMessage.welcome(chats: chats));
      }

      // From here on, this pair can redial without the window — and this
      // device starts listening for one, which before a pairing it had no
      // reason to be doing.
      _allowReconnect(deviceId, psk);
      unawaited(ensureReady());
      _note(PairingStage.done);
    } catch (error) {
      logFailure("sync", "could not establish a channel", error);
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
    logFailure("sync", "pairing failed", error);
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
