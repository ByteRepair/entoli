import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../core/log.dart";
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
import "pairing.dart";
import "peers.dart";
import "sync_byte_cache.dart";

// The two extracted pieces' types are part of what a `SyncHub` hands out.
export "peers.dart" show PeerState, PeerStatus;
export "pairing.dart" show PairingActivity, PairingStage;
export "signaling/pairing_payload.dart"
    show PairingOffer, generatePairingCode, generatePsk;

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

/// What two Entolis do with a channel once [SyncPairing] has opened one:
/// serve this device's chats to whoever is watching, and hold a copy of the
/// ones it watches elsewhere. Both at once, always — and in one file, because
/// they are the two ends of the same twelve messages. See this directory's
/// CLAUDE.md for why that is not two files.
class SyncHub {
  SyncHub({
    required this.identity,
    required this.registry,
    required AppSettings Function() settings,
    String? Function()? turnPassword,
    required LanSignaling? Function() lanSignaling,
    String? hostname,
    http.Client? client,
    RelayDial? relayDial,
  }) {
    _signaling = SyncPairing(
      identity: identity,
      registry: registry,
      settings: settings,
      turnPassword: turnPassword,
      peers: _peers,
      lanSignaling: lanSignaling,
      onMessage: _dispatch,
      onPeerGone: _peerGone,
      onReady: _greet,
      hostname: hostname,
      client: client,
      relayDial: relayDial,
    );
  }

  final SyncIdentity identity;
  final DeviceRegistry registry;

  late final SyncPeers _peers = SyncPeers(registry);

  /// Getting two devices talking, and keeping a way back.
  late final SyncPairing _signaling;

  /// Every paired device with how it stands. The UI's whole view of sync.
  ValueNotifier<Map<String, PeerState>> get peers => _peers.states;

  // What the pairing side hands out, forwarded so that it stays the hub a
  // page or a test is given.
  ValueNotifier<PairingActivity?> get pairing => _signaling.activity;
  String get deviceName => _signaling.deviceName;
  String get defaultDeviceName => _signaling.defaultDeviceName;
  Future<PairingActivity> startPairingWindow() => _signaling.startPairingWindow();
  void cancelPairingWindow() => _signaling.cancelPairingWindow();
  Future<String?> pairWith(String text) => _signaling.pairWith(text);
  Future<String> createManualInvite() => _signaling.createManualInvite();
  void cancelManualInvite() => _signaling.cancelManualInvite();
  void confirmPairing(bool ok) => _signaling.confirmPairing(ok);
  Future<void> connect(String deviceId) => _signaling.connect(deviceId);
  Future<void> disconnect(String deviceId) => _signaling.disconnect(deviceId);
  Future<void> ensureReady() => _signaling.ensureReady();

  @visibleForTesting
  bool admitsReconnect(String psk) => _signaling.admitsReconnect(psk);

  @visibleForTesting
  Future<void> establishForTest({
    required ByteChannel link,
    required bool weOffered,
    required String psk,
    String? knownDeviceId,
  }) =>
      _signaling.establishForTest(
          link: link,
          weOffered: weOffered,
          psk: psk,
          knownDeviceId: knownDeviceId);

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

  /// A peer finished the handshake: what this device serves goes out first.
  /// The mirror side answers it with chatOpens for whatever it follows.
  Future<void> _greet(LivePeer peer) async {
    final repo = _repo;
    if (repo == null) return;
    final chats = await repo.listChats();
    _announced = {for (final chat in chats) chat.id};
    await peer.send(SyncMessage.welcome(chats: chats));
  }

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

  // --------------------------------------------- a connection ending

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

  Future<void> dispose() async {
    // Before the peers go: a handshake parked at the codes-matched gate
    // unwinds only when this completes its confirmation, and its tail would
    // otherwise file a peer into a registry that has already been torn down.
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
    await _signaling.dispose();
  }

  /// Unpairs: drops the record, its secret, and any live connection. The
  /// other device keeps ours until someone revokes there too.
  Future<void> revoke(String deviceId) async {
    await _peers.remove(deviceId)?.close();
    await _signaling.forgetDevice(deviceId);
    // By hand, both of them: a registry read only fills gaps, so the row and
    // the mirrors would stay listed, and online, until a restart.
    for (final chatId in _mirrorsOf(deviceId)) {
      _dropMirror(deviceId, chatId);
    }
    _peers.forget(deviceId);
    _rebuildRemotes();
    unawaited(_peers.refresh());
  }

}

/// One resource transfer in flight: chunks accumulate until `done`.
class _ResourceTransfer {
  final completer = Completer<Uint8List?>();
  final buffer = BytesBuilder(copy: false);
}
