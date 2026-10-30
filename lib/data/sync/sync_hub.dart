import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../core/log.dart";
import "../builtin/memory/store.dart" show Memories, MemoryEntry;
import "../../domain/app_settings.dart";
import "../../domain/project.dart" show ProjectRef, everyProject, isProjectName;
import "../../domain/project_settings.dart";
import "../../domain/chat_log.dart" show ChatRecord, PartRecord, chatFrom;
import "../../domain/chat_meta.dart";
import "../../domain/chat_repository.dart";
import "../../domain/models.dart"
    show ArtifactPart, Attachment, Chat, ChatState, ToolApproval;
import "../../domain/prompt_library.dart";
import "../../domain/sub_agent_log.dart" show SubAgentAppend, growTranscript;
import "../../domain/sync/devices.dart";
import "../../domain/sync/identity.dart";
import "../../domain/sync/lan_signaling.dart";
import "../../domain/sync/protocol.dart";
import "../../domain/sync/relay_signaling.dart";
import "artifact_bytes.dart" show ArtifactBytes;
import "channel.dart";
import "pairing.dart";
import "peers.dart";
import "sync_byte_cache.dart";

// The two extracted pieces' types are part of what a `SyncHub` hands out.
export "peers.dart" show PeerState, PeerStatus, SyncPeers;
export "pairing.dart" show PairingActivity, PairingStage;
export "signaling/pairing_payload.dart"
    show PairingOffer, generatePairingCode, generatePsk;

/// One of a peer's chats, as this device mirrors it. RAM-only: nothing here
/// is ever written to the data directory, so no backup carries it.
class MirrorChat {
  MirrorChat({
    required this.peerId,
    required this.deviceName,
    required this.state,
    required this.meta,
  });

  final String peerId;

  /// The home device's name as the connection presented it when the mirror
  /// was created — the address book's, where one exists; else the hello's.
  /// Fallback only: the Remotes rows derive their name from the device's
  /// [PeerState] (which a rename updates) and reach for this when the device
  /// has gone missing from it.
  final String deviceName;
  ChatState state;
  ChatMeta meta;
  final List<ChatRecord> records = [];

  /// The turn, as the home device last reported it. None of this is in the
  /// log — a running turn, a command waiting to be allowed, a question
  /// waiting to be answered — so it arrives as its own message.
  bool running = false;
  List<ToolApproval> approvals = const [];
  List<SyncAsk> asks = const [];
  String? status;
  String? retry;

  /// The sub-agent transcripts followed here, by the call that spawned them.
  final Map<String, List<ChatRecord>> subAgents = {};

  @override
  String toString() => "MirrorChat(${state.id}, ${records.length} records)";
}

/// What a chat's home device does when the mirror holding it drives a turn.
/// Registered on the [SyncHub] by the container, because running a turn is
/// `ChatController`'s and the hub has no way to reach one — the same reason
/// the repository arrives through [SyncHub.attach].
abstract interface class RemoteTurns {
  void prompt(String chatId, String text,
      {List<Attachment> attachments, bool queue});
  void resume(String chatId);
  void abort(String chatId);
  void approve(String chatId, String approvalId, bool allow);
  void answer(String chatId, String requestId, List<String?> answers);
  void editResend(String chatId, String messageId, String text);
  void regenerate(String chatId, String messageId);
  void stepThread(String chatId, String messageId, int step);
  void deleteThread(String chatId, String messageId);
  Future<void> saveState(String chatId, ChatState state, {required bool reanchor});
  Future<void> saveMeta(String chatId, ChatMeta meta);
  Future<void> retitle(String chatId, String title);
  Future<void> delete(String chatId);
  /// A chat made in [project] for a paired device to say the first thing in.
  Future<String> startChat(String? project);
  ProjectSettings projectSettings(String? project);
  AppSettings get appSettings;
  Future<void> writeProject(String? project, ProjectSettings settings);
  Future<void> createProject(String name);
  Future<void> deleteProject(String name);
  PromptLibrary library(String? project);
  Memories memories(String? project);
}

/// A paired device's project, while something here is showing it: its
/// settings, the app settings they inherit from, and its skills and agents.
/// RAM-only like a mirror, and only while followed.
class RemoteProject {
  RemoteProject(this.settings, this.app, [PromptLibrary? library])
      : library = library ?? PromptLibrary.empty;

  final ProjectSettings settings;
  final AppSettings app;
  final PromptLibrary library;
}

/// A paired device's project's memories, asked for on every call and held
/// nowhere: a call throws where the device is away, so a page keeps what it
/// last drew.
class RemoteMemories implements Memories {
  RemoteMemories(this._hub, this.project);

  final SyncHub _hub;
  final ProjectRef project;

  @override
  Future<List<MemoryEntry>> entries() => _hub.callMemories(project, "list");

  @override
  Future<List<MemoryEntry>> search(String query) =>
      _hub.callMemories(project, "search", text: query);

  @override
  Future<void> add(String text) => _hub.callMemories(project, "add", text: text);

  @override
  Future<void> pin(String id) => _hub.callMemories(project, "pin", id: id);

  @override
  Future<void> unpin(String id) => _hub.callMemories(project, "unpin", id: id);

  @override
  Future<void> delete(String id) => _hub.callMemories(project, "delete", id: id);
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
    this.omada = false,
  });

  final String chatId;
  final String deviceId;
  final String deviceName;
  final ChatState state;
  final bool online;

  /// Whether the chat's project runs Omada on its home device.
  final bool omada;

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
      other.omada == omada &&
      other.state == state;

  @override
  int get hashCode =>
      Object.hash(chatId, deviceId, deviceName, online, omada, state);
}

/// What two Entolis do with a channel once [SyncPairing] has opened one:
/// serve this device's chats to whoever is watching, and hold a copy of the
/// ones it watches elsewhere. Both at once, always — and in one file, because
/// they are the two ends of the same twelve messages. See this directory's
/// AGENTS.md for why that is not two files.
class SyncHub implements ArtifactBytes, RemoteChats {
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

  /// Ends a pairing in flight — the verb every pairing screen's back and
  /// Done is; [cancelPairingWindow] adds the window's own teardown.
  void cancelPairing() => _signaling.cancelPairing();
  Future<String?> pairWith(String text) => _signaling.pairWith(text);
  Future<String> createManualInvite() => _signaling.createManualInvite();
  void cancelManualInvite() => _signaling.cancelManualInvite();
  void confirmPairing(bool ok) => _signaling.confirmPairing(ok);
  Future<void> connect(String deviceId) => _signaling.connect(deviceId);
  Future<void> disconnect(String deviceId) => _signaling.disconnect(deviceId);
  Future<void> ensureReady() => _signaling.ensureReady();

  @visibleForTesting
  bool admitsReconnect(String psk) => _signaling.admitsReconnect(psk);

  /// The codes-matched gate's own decision, pinned without racing a real
  /// handshake: with no pairing open to ask on, a fresh pair must fail
  /// rather than arm a confirmation nothing can complete.
  @visibleForTesting
  Future<bool> pairingGateForTest(String sas, String peerName,
          {required bool isNew}) =>
      _signaling.confirmGateForTest(sas, peerName, isNew: isNew);

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
  StreamSubscription<SubAgentAppend>? _subAgentSub;

  /// The peer's chats this device mirrors, by chat id. Survives a disconnect
  /// as a stale snapshot; a reconnect replaces it wholesale with fresh data.
  final _mirrors = <String, MirrorChat>{};

  /// Chat ids being followed across reconnects — what [followChat] added and
  /// [unfollowChat] has not removed. On every welcome these are re-opened
  /// from where the mirror already is.
  final _desired = <String>{};

  /// Set by the container once there is a way to run a turn. Null until then,
  /// which is every test that is only about the wire.
  RemoteTurns? remoteTurns;

  /// Mirrored attachments, held only as long as the mirror is. Owned here
  /// rather than beside the page that shows them so that a mirror going
  /// takes its megabytes with it.
  final byteCache = SyncByteCache();

  final _mirrorUpdates = StreamController<String>.broadcast();

  Stream<String> get mirrorUpdates => _mirrorUpdates.stream;

  /// The sub-agent transcripts followed here, as (chatId, callId) — re-opened
  /// on a reconnect like [_desired].
  final _desiredSubAgents = <(String, String)>{};

  final _subAgentUpdates =
      StreamController<({String chatId, String callId})>.broadcast();

  /// A followed sub-agent's transcript moved. Its own stream rather than
  /// [mirrorUpdates], which replays the whole conversation per event.
  Stream<({String chatId, String callId})> get subAgentUpdates =>
      _subAgentUpdates.stream;

  /// The Remotes section of the sidebar: one entry per mirrored chat, flat,
  /// rebuilt whenever anything under it moves.
  final remotes = ValueNotifier<List<RemoteChatEntry>>(const []);

  ValueNotifier<Set<String>> get servedChats => _peers.servedChats;

  MirrorChat? mirror(String chatId) => _mirrors[chatId];

  /// Whether the connection to [chatId]'s home device is up. False for a
  /// stale snapshot: the page disables the composer and shows its banner.
  bool isChatOnline(String chatId) =>
      _peers.hasLive(_mirrors[chatId]?.peerId);

  /// Per peer, its projects with Omada on, as its last listing named them.
  final _omadaProjects = <String, Set<String>>{};

  /// Per paired device, the projects it named last: its own, the default and
  /// the built-ins being on every device. Kept while it is away, so its
  /// projects stay listed, read-only, until it is back.
  final deviceProjects = ValueNotifier<Map<String, List<String>>>(const {});

  final _projects = <ProjectRef, RemoteProject>{};
  final _followedProjects = <ProjectRef>{};
  final _projectUpdates = StreamController<ProjectRef>.broadcast();

  Stream<ProjectRef> get projectUpdates => _projectUpdates.stream;

  ValueNotifier<Set<String?>> get servedProjects => _peers.servedProjects;

  /// [project] as its device last said, or null until it has.
  RemoteProject? remoteProject(ProjectRef project) => _projects[project];

  bool isDeviceOnline(String deviceId) => _peers.hasLive(deviceId);

  /// Read a paired device's project from now until [unfollowProject]. A
  /// device away now is asked when it is back.
  void followProject(ProjectRef project) {
    _followedProjects.add(project);
    unawaited(_peers[project.device!]
        ?.send(SyncMessage.projectOpen(project: project.project)));
  }

  /// Not cached past being shown: what was read goes with the follow.
  void unfollowProject(ProjectRef project) {
    _followedProjects.remove(project);
    _projects.remove(project);
    unawaited(_peers[project.device!]
        ?.send(SyncMessage.projectClose(project: project.project)));
  }

  /// A chat in a paired device's [project], started there with [text] and
  /// held by this device. The reply carries its id once that device has
  /// listed it; null where the device is away or did not answer.
  Future<SyncReply?> startRemoteChat(ProjectRef project, String text,
      {List<Attachment> attachments = const []}) async {
    return _ask(
        _peers[project.device!],
        "a chat in ${project.project}",
        (id) => SyncMessage.chatStart(
            requestId: id, project: project.project, text: text, files: _files(attachments)));
  }

  /// Whether [settings] landed. A follower has the snapshot of them first.
  Future<bool> writeRemoteProject(ProjectRef project, ProjectSettings settings) async =>
      (await _ask(
              _peers[project.device!],
              "${project.project}",
              (id) => SyncMessage.projectWrite(
                  requestId: id, project: project.project, settings: settings)))
          ?.ok ??
      false;

  /// Whether [name] was made, with [settings] where given. Its listing has
  /// arrived by the time this answers.
  Future<bool> createRemoteProject(String deviceId, String name,
          {ProjectSettings? settings}) async =>
      (await _ask(
              _peers[deviceId],
              name,
              (id) => SyncMessage.projectCreate(
                  requestId: id, name: name, settings: settings)))
          ?.ok ??
      false;

  Future<bool> deleteRemoteProject(String deviceId, String name) async =>
      (await _ask(_peers[deviceId], name,
              (id) => SyncMessage.projectDelete(requestId: id, name: name)))
          ?.ok ??
      false;

  /// Home side: tell whoever follows [project] what its settings are now.
  void publishProject(String? project) => _publish(project, prompts: false);

  /// Home side: the same for its skills and agents.
  void publishPrompts(String? project) => _publish(project, settings: false);

  void _publish(String? project, {bool settings = true, bool prompts = true}) {
    for (final peer in _peers.live) {
      if (peer.projectSubscriptions.contains(project)) {
        unawaited(_sendProject(peer, project, settings: settings, prompts: prompts));
      }
    }
  }

  /// [op] on a paired device's [project]'s memories, and what they read after
  /// it — the search's answer for a search. Throws where the device is away
  /// or did not go through with it.
  Future<List<MemoryEntry>> callMemories(ProjectRef project, String op,
      {String? id, String? text}) async {
    final reply = await _ask(
        _peers[project.device!],
        "memory $op in ${project.project}",
        (requestId) => SyncMessage.memoryCall(
            requestId: requestId, project: project.project, op: op, id: id, text: text));
    if (reply == null || !reply.ok) throw StateError("memories of ${project.device}: $op failed");
    return reply.entries.map(MemoryEntry.fromJson).toList();
  }

  Future<void> _serveMemories(LivePeer peer, SyncMemoryCall call) async {
    final turns = remoteTurns;
    List<MemoryEntry>? read;
    if (turns != null && await _isProject(call.project)) {
      final store = turns.memories(call.project);
      try {
        switch ((call.op, call.id, call.text)) {
          case ("add", _, final String text):
            await store.add(text);
          case ("pin", final String id, _):
            await store.pin(id);
          case ("unpin", final String id, _):
            await store.unpin(id);
          case ("delete", final String id, _):
            await store.delete(id);
          case ("list" || "search", _, _):
            break;
          default:
            // An unknown op, or one missing what it needs, must not read as
            // done.
            throw ArgumentError.value(call.op, "op", "not a memory call");
        }
        read = call.op == "search"
            ? await store.search(call.text ?? "")
            : await store.entries();
      } catch (e) {
        logFailure("sync", "memory ${call.op} for ${peer.deviceId}", e);
      }
    }
    await peer.send(SyncMessage.reply(
        requestId: call.requestId,
        ok: read != null,
        entries: [for (final e in read ?? const <MemoryEntry>[]) e.toJson()]));
  }

  Future<bool> _isProject(String? project) async {
    final repo = _repo;
    return repo != null && everyProject(await repo.listProjects()).contains(project);
  }

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
    _repo = repo..remote = this;
    _changesSub = repo.changes.listen(_onRepoEvent);
    _subAgentSub = repo.subAgentAppends.listen(_onSubAgentAppended);
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

  /// What this device holds of a mirrored sub-agent's transcript. Null until
  /// it has been followed and answered.
  List<ChatRecord>? subAgentRecords(String chatId, String callId) =>
      _mirrors[chatId]?.subAgents[callId];

  /// Follow a sub-agent's transcript on the chat's home device, from what is
  /// already held here.
  void followSubAgent(String chatId, String callId) {
    _desiredSubAgents.add((chatId, callId));
    final peer = _peerHosting(chatId);
    if (peer != null) _openSubAgentOnPeer(peer, chatId, callId);
  }

  /// Unlike a chat, said to the home device: a running sub-agent appends
  /// every second, to a drawer nobody has open any more.
  void unfollowSubAgent(String chatId, String callId) {
    _desiredSubAgents.remove((chatId, callId));
    unawaited(_peerHosting(chatId)
        ?.send(SyncMessage.subAgentClose(chatId: chatId, callId: callId)));
  }

  void _openSubAgentOnPeer(LivePeer peer, String chatId, String callId) {
    unawaited(peer.send(SyncMessage.subAgentOpen(
      chatId: chatId,
      callId: callId,
      fromLine: subAgentRecords(chatId, callId)?.length ?? 0,
    )));
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
    final transfer = _pendingResources[id] = _ResourceTransfer(peer.deviceId);
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
  /// notify whoever is watching.
  Future<void> _dispatch(LivePeer peer, SyncMessage message) async {
    switch (message) {
      case SyncPing():
        await peer.send(const SyncMessage.pong());
      case SyncPong():
        break; // its frame was counted on arrival, in [SecureChannel.lastFrame]
      case SyncReply():
        break; // the asker's echo, matched below
      case SyncWelcome(:final chats, :final omadaProjects, :final projects) ||
            SyncChatsChanged(:final chats, :final omadaProjects, :final projects):
        _omadaProjects[peer.deviceId] = omadaProjects.toSet();
        deviceProjects.value = {...deviceProjects.value, peer.deviceId: projects};
        await _applyWelcome(peer, chats, reconnect: message is SyncWelcome);
        // A reconnect reads what is open again rather than trusting what it
        // last had; a project gone at home goes here too.
        final every = everyProject(projects);
        for (final followed in _followedProjects) {
          if (followed.device != peer.deviceId) continue;
          if (!every.contains(followed.project)) {
            if (_projects.remove(followed) != null) _projectUpdates.add(followed);
          } else if (message is SyncWelcome) {
            unawaited(peer.send(SyncMessage.projectOpen(project: followed.project)));
          }
        }
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
        // A re-publish names its artifact again; a zip fetched before that
        // is stale, and this is where a mirror can tell.
        for (final record in records) {
          if (record case PartRecord(part: ArtifactPart(:final artifactId))) {
            byteCache.dropResource(chatId, "$_artifactPrefix$artifactId");
          }
        }
      case SyncSubAgentOpen(:final chatId, :final callId, :final fromLine):
        await _serveSubAgentOpen(peer, chatId, callId, fromLine);
      case SyncSubAgentClose(:final chatId, :final callId):
        peer.subAgentFollows.remove((chatId, callId));
      case SyncSubAgentAppend(
          :final chatId,
          :final callId,
          :final from,
          :final records
        ):
        _onSubAgentAppend(peer, chatId, callId, from, records);
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
        _collectResourceChunk(peer, id, bytesB64, done);
      case final SyncMemoryCall call:
        await _serveMemories(peer, call);

      // -- serving: a paired device driving one of this device's chats
      case SyncPromptSend(
          :final requestId,
          :final chatId,
          :final text,
          :final files,
          :final queue
        ):
        final turns = remoteTurns;
        final ok = turns != null && _follows(peer, chatId);
        if (ok) {
          turns.prompt(chatId, text,
              attachments: _attachments(files), queue: queue);
        }
        await peer.send(SyncMessage.reply(requestId: requestId, ok: ok));
      case SyncTurnResume(:final chatId):
        if (_follows(peer, chatId)) remoteTurns?.resume(chatId);
      case SyncTurnAbort(:final chatId):
        if (_follows(peer, chatId)) remoteTurns?.abort(chatId);
      case SyncApprovalRespond(:final chatId, :final approvalId, :final allow):
        if (_follows(peer, chatId)) {
          remoteTurns?.approve(chatId, approvalId, allow);
        }
      case SyncQuestionsRespond(
          :final chatId,
          :final requestId,
          :final answers
        ):
        if (_follows(peer, chatId)) {
          remoteTurns?.answer(chatId, requestId, answers);
        }
      case SyncEditResend(:final chatId, :final messageId, :final text):
        if (_follows(peer, chatId)) {
          remoteTurns?.editResend(chatId, messageId, text);
        }
      case SyncRegenerate(:final chatId, :final messageId):
        if (_follows(peer, chatId)) remoteTurns?.regenerate(chatId, messageId);
      case SyncThreadStep(:final chatId, :final messageId, :final step):
        if (_follows(peer, chatId)) {
          remoteTurns?.stepThread(chatId, messageId, step);
        }
      case SyncThreadDelete(:final chatId, :final messageId):
        if (_follows(peer, chatId)) remoteTurns?.deleteThread(chatId, messageId);

      // -- serving: a paired device is the user's own, so no lock for these
      case SyncStateWrite(:final chatId, :final state, :final reanchor):
        // The id and where the chat is are this device's: a move is not a
        // state write.
        final current = await _ours(chatId);
        if (current != null) {
          await remoteTurns?.saveState(
              chatId, state.copyWith(id: chatId, project: current.project),
              reanchor: reanchor);
          await _answerWriter(peer, chatId);
        }
      case SyncMetaWrite(:final chatId, :final meta):
        if (await _ours(chatId) != null) {
          await remoteTurns?.saveMeta(chatId, meta);
          await _answerWriter(peer, chatId);
        }
      case SyncRetitle(:final chatId, :final title):
        if (await _ours(chatId) != null) {
          await remoteTurns?.retitle(chatId, title);
          await _answerWriter(peer, chatId);
        }
      case SyncChatDelete(:final chatId):
        if (await _ours(chatId) != null) await remoteTurns?.delete(chatId);

      case SyncChatStart(:final requestId, :final project, :final text, :final files):
        final turns = remoteTurns;
        String? chatId;
        if (turns != null && await _isProject(project)) {
          chatId = await turns.startChat(project);
          // Listed before it is answered, so the asker has the mirror to open.
          await _announceChats();
          turns.prompt(chatId, text, attachments: _attachments(files));
        }
        await peer.send(
            SyncMessage.reply(requestId: requestId, ok: chatId != null, chatId: chatId));

      // -- serving: a project of this device
      case SyncProjectOpen(:final project):
        if (await _isProject(project)) {
          peer.projectSubscriptions.add(project);
          _peers.refreshServed();
          await _sendProject(peer, project);
        }
      case SyncProjectClose(:final project):
        peer.projectSubscriptions.remove(project);
        _peers.refreshServed();
      case SyncProjectWrite(:final requestId, :final project, :final settings):
        await _answer(peer, requestId, "write to $project", () async {
          if (!await _isProject(project)) return false;
          await remoteTurns!.writeProject(project, settings);
          return true;
        });
      case SyncProjectCreate(:final requestId, :final name, :final settings):
        await _answer(peer, requestId, "create $name", () async {
          if (!isProjectName(name) || await _isProject(name)) return false;
          await remoteTurns!.createProject(name);
          if (settings != null) await remoteTurns!.writeProject(name, settings);
          // Listed before it is answered, so the asker can select it.
          await _announceChats();
          return true;
        });
      case SyncProjectDelete(:final requestId, :final name):
        await _answer(peer, requestId, "delete $name", () async {
          if (!isProjectName(name) || !await _isProject(name)) return false;
          await remoteTurns!.deleteProject(name);
          await _announceChats();
          return true;
        });

      // -- mirroring: a project of the peer's this device has open
      case SyncProjectSnapshot(:final project, :final settings, :final app):
        final ProjectRef ref = (device: peer.deviceId, project: project);
        if (_followedProjects.contains(ref)) {
          _projects[ref] = RemoteProject(settings, app, _projects[ref]?.library);
          _projectUpdates.add(ref);
        }
      case SyncProjectPrompts(:final project, :final documents):
        final ProjectRef ref = (device: peer.deviceId, project: project);
        final held = _projects[ref];
        if (held != null && _followedProjects.contains(ref)) {
          _projects[ref] = RemoteProject(held.settings, held.app,
              PromptLibrary(documents.map(PromptDocument.fromJson)));
          _projectUpdates.add(ref);
        }

      // -- mirroring: what the home device says about a chat we follow
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
    for (final echo in [..._echoes]) {
      if (echo.peerId == peer.deviceId &&
          !echo.done.isCompleted &&
          echo.matches(message)) {
        echo.done.complete(message);
      }
    }
  }

  /// Run [act] and tell [peer] whether it went through. Queued behind the
  /// project sends, so the snapshot a write set off reaches a follower first.
  Future<void> _answer(LivePeer peer, String requestId, String what,
      Future<bool> Function() act) async {
    var ok = false;
    if (remoteTurns != null) {
      try {
        ok = await act();
      } catch (e) {
        logFailure("sync", "$what for ${peer.deviceId}", e);
      }
    }
    await _inOrder(peer, () => peer.send(SyncMessage.reply(requestId: requestId, ok: ok)));
  }

  /// Per peer, the last project send, so a write's reply goes out behind the
  /// snapshot it set off.
  final _projectSends = Expando<Future<void>>();

  Future<void> _inOrder(LivePeer peer, Future<void> Function() send) =>
      _projectSends[peer] = (_projectSends[peer] ?? Future.value())
          .catchError((Object _) {})
          .then((_) => send());

  /// [project]'s settings, its skills and agents, or both.
  Future<void> _sendProject(LivePeer peer, String? project,
          {bool settings = true, bool prompts = true}) =>
      _inOrder(peer, () async {
        final turns = remoteTurns;
        if (turns == null) return;
        if (settings) {
          await peer.send(SyncMessage.projectSnapshot(
              project: project,
              settings: turns.projectSettings(project),
              app: turns.appSettings));
        }
        if (prompts) {
          await peer.send(SyncMessage.projectPrompts(
              project: project,
              documents: [for (final d in turns.library(project).all) d.toJson()]));
        }
      });

  /// [chatId]'s head where it is one of this device's chats: a write naming
  /// any other id would otherwise create one.
  Future<ChatState?> _ours(String chatId) async {
    final state = await _repo?.loadState(chatId);
    if (state == null) logFailure("sync", "a peer wrote to $chatId, not on this device");
    return state;
  }

  /// A writer following the chat heard the write as a subscriber; one that
  /// is not — a rename from the sidebar — is told here, or it waits on an
  /// echo that never comes.
  Future<void> _answerWriter(LivePeer peer, String chatId) async {
    final repo = _repo;
    if (repo == null || peer.subscriptions.contains(chatId)) return;
    final (state, meta) = await (repo.loadState(chatId), repo.loadMeta(chatId)).wait;
    if (state == null) return;
    await peer.send(SyncMessage.metaPatch(chatId: chatId, meta: meta));
    await peer.send(SyncMessage.stateDiff(chatId: chatId, state: state));
  }

  final _echoes =
      <({String peerId, bool Function(SyncMessage) matches, Completer<SyncMessage?> done})>[];

  /// Send a write to [chatId]'s home device and wait for the message that
  /// says it landed, so whoever awaits it draws the result rather than what
  /// was asked for. A home device gone or silent ends the wait unwritten.
  Future<void> _write(String chatId, SyncMessage message,
          bool Function(SyncMessage) echo) =>
      _send(_peerHosting(chatId), chatId, message, echo);

  /// The message [echo] matched, or null where none came.
  Future<SyncMessage?> _send(LivePeer? peer, String about, SyncMessage message,
      bool Function(SyncMessage) echo) async {
    if (peer == null) {
      logFailure("sync", "${message.runtimeType} for $about: home device is offline");
      return null;
    }
    final waiter = (peerId: peer.deviceId, matches: echo, done: Completer<SyncMessage?>());
    _echoes.add(waiter);
    try {
      await peer.send(message);
      return await waiter.done.future.timeout(const Duration(seconds: 30), onTimeout: () {
        logFailure("sync", "${message.runtimeType} for $about: no answer");
        return null;
      });
    } finally {
      _echoes.remove(waiter);
    }
  }

  /// A request built with its id, and the [SyncReply] that answers it.
  Future<SyncReply?> _ask(LivePeer? peer, String about,
      SyncMessage Function(String requestId) request) async {
    final id = "q${_resourceSeq++}";
    final reply = await _send(
        peer, about, request(id), (m) => m is SyncReply && m.requestId == id);
    if (reply case SyncReply(ok: false)) logFailure("sync", "$about: refused");
    return reply as SyncReply?;
  }

  @override
  ChatState? stateOf(String chatId) => _mirrors[chatId]?.state;

  @override
  Chat? chatOf(String chatId) {
    final mirror = _mirrors[chatId];
    return mirror == null ? null : chatFrom(mirror.state, mirror.records);
  }

  @override
  // A copy: the settings page edits what it is given in place.
  ChatMeta? metaOf(String chatId) => _mirrors[chatId]?.meta.copy();

  @override
  Future<ChatState> saveState(ChatState state, {required bool reanchor}) async {
    await _write(
        state.id,
        SyncMessage.stateWrite(chatId: state.id, state: state, reanchor: reanchor),
        (m) => m is SyncStateDiff && m.chatId == state.id);
    return _mirrors[state.id]?.state ?? state;
  }

  @override
  Future<void> saveMeta(String chatId, ChatMeta meta) => _write(
      chatId,
      SyncMessage.metaWrite(chatId: chatId, meta: meta),
      (m) => m is SyncMetaPatch && m.chatId == chatId);

  @override
  Future<void> retitle(String chatId, String title) => _write(
      chatId,
      SyncMessage.retitle(chatId: chatId, title: title),
      (m) => m is SyncStateDiff && m.chatId == chatId);

  @override
  Future<void> delete(String chatId) => _write(
      chatId,
      SyncMessage.chatDelete(chatId: chatId),
      (m) => m is SyncChatDeleted && m.chatId == chatId);

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

  /// A followed sub-agent's records, from its chat's home device. A gap is
  /// records missed — an append that crossed the open — so the transcript is
  /// asked for again from what is held.
  void _onSubAgentAppend(LivePeer peer, String chatId, String callId, int from,
      List<ChatRecord> records) {
    final mirror = _mirrors[chatId];
    if (mirror == null || mirror.peerId != peer.deviceId) return;
    if (!_desiredSubAgents.contains((chatId, callId))) return;
    final grown =
        growTranscript(mirror.subAgents[callId] ?? const [], from, records);
    if (grown == null) {
      _openSubAgentOnPeer(peer, chatId, callId);
      return;
    }
    mirror.subAgents[callId] = grown;
    if (!_subAgentUpdates.isClosed) {
      _subAgentUpdates.add((chatId: chatId, callId: callId));
    }
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

  /// Whether [peer] has [chatId] open. Every arm that drives a turn goes
  /// through it: a paired device is the user's own, so following the chat is
  /// all it takes, and an id it was never shown names nothing to drive.
  bool _follows(LivePeer peer, String chatId) => peer.subscriptions.contains(chatId);

  /// A fresh listing from the peer. Mirrors of this peer not in it go; those
  /// in it are added or refreshed — keeping records already held, so the
  /// re-opens below resume rather than restart. Then, on a [reconnect],
  /// everything this device follows and still sees is asked for again, from
  /// where it got to; otherwise only what it follows and has just seen. A
  /// chat open already is not re-opened: the records a turn appends while the
  /// home device reads its log would arrive twice.
  Future<void> _applyWelcome(LivePeer peer, List<ChatState> chats,
      {required bool reconnect}) async {
    final added = <String>{};
    final listed = {for (final c in chats) c.id: c};
    for (final id in _mirrors.keys.toList()) {
      if (_mirrors[id]!.peerId == peer.deviceId && !listed.containsKey(id)) {
        _dropMirror(peer.deviceId, id);
      }
    }
    for (final state in chats) {
      final existing = _mirrors[state.id];
      if (existing != null && existing.peerId != peer.deviceId) continue;
      if (existing == null) added.add(state.id);
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
      if (reconnect ? listed.containsKey(id) : added.contains(id)) _openOnPeer(peer, id);
    }
    // After the chats: the home device takes a sub-agent's open only from a
    // peer already following its chat.
    for (final (chatId, callId) in _desiredSubAgents) {
      if (_desired.contains(chatId) &&
          (reconnect ? listed.containsKey(chatId) : added.contains(chatId))) {
        _openSubAgentOnPeer(peer, chatId, callId);
      }
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

  /// A peer following [chatId] wants one of its sub-agents' transcripts. The
  /// follow goes in before the read, so an append landing during it arrives
  /// twice rather than not at all — the numbering drops the second copy.
  Future<void> _serveSubAgentOpen(
      LivePeer peer, String chatId, String callId, int fromLine) async {
    final repo = _repo;
    if (repo == null || !_follows(peer, chatId)) return;
    peer.subAgentFollows.add((chatId, callId));
    final records = await repo.subAgentRecords(chatId, callId);
    await peer.send(SyncMessage.subAgentAppend(
      chatId: chatId,
      callId: callId,
      from: fromLine,
      records: fromLine < records.length ? records.sublist(fromLine) : const [],
    ));
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
        _announced.remove(chatId);
        _peers.refreshServed();
      case ProjectsChanged():
        unawaited(_announceChats());
    }
  }

  /// A running sub-agent's appends, to the peers following its transcript.
  void _onSubAgentAppended(SubAgentAppend append) {
    final message = SyncMessage.subAgentAppend(
      chatId: append.chatId,
      callId: append.callId,
      from: append.from,
      records: append.records,
    );
    for (final peer in _peers.live) {
      if (peer.subAgentFollows.contains((append.chatId, append.callId))) {
        unawaited(peer.send(message));
      }
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
    await peer.send(SyncMessage.welcome(
        chats: chats,
        omadaProjects: repo.omadaProjects(chats),
        projects: await repo.listProjects()));
  }

  Future<void> _announceChats() async {
    final repo = _repo;
    if (repo == null || _peers.isEmpty) return;
    final chats = await repo.listChats();
    _announced = {for (final chat in chats) chat.id};
    final message = SyncMessage.chatsChanged(
        chats: chats,
        omadaProjects: repo.omadaProjects(chats),
        projects: await repo.listProjects());
    for (final peer in _peers.live) {
      unawaited(peer.send(message));
    }
  }

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

  /// Drive a turn on the chat's home device, which runs it. Null where the
  /// device is away or did not answer.
  Future<SyncReply?> sendRemotePrompt(String chatId, String text,
      {List<Attachment> attachments = const [], bool queue = false}) async {
    return _ask(
        _peerHosting(chatId),
        "a prompt in $chatId",
        (id) => SyncMessage.promptSend(
            requestId: id,
            chatId: chatId,
            text: text,
            files: _files(attachments),
            queue: queue));
  }

  static List<SyncFile> _files(List<Attachment> attachments) => [
        for (final a in attachments)
          SyncFile(bytesB64: base64Encode(a.bytes), filename: a.filename, mimeType: a.mimeType),
      ];

  static List<Attachment> _attachments(List<SyncFile> files) => [
        for (final f in files)
          Attachment(filename: f.filename, mimeType: f.mimeType, bytes: base64Decode(f.bytesB64)),
      ];

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

  Future<void> editRemote(String chatId, String messageId, String text) => _drive(
      chatId, SyncMessage.editResend(chatId: chatId, messageId: messageId, text: text));

  Future<void> regenerateRemote(String chatId, String messageId) =>
      _drive(chatId, SyncMessage.regenerate(chatId: chatId, messageId: messageId));

  Future<void> stepThreadRemote(String chatId, String messageId, int step) => _drive(
      chatId, SyncMessage.threadStep(chatId: chatId, messageId: messageId, step: step));

  Future<void> deleteThreadRemote(String chatId, String messageId) =>
      _drive(chatId, SyncMessage.threadDelete(chatId: chatId, messageId: messageId));

  Future<void> _drive(String chatId, SyncMessage message) async =>
      _peerHosting(chatId)?.send(message);

  /// Any message straight to the chat's home device, for a test of what that
  /// device refuses.
  @visibleForTesting
  Future<void> sendForTest(String chatId, SyncMessage message) async =>
      _peerHosting(chatId)?.send(message);

  /// An attachment's chunk, in source bytes: the framing would carry it
  /// whole, but a file is not held as one base64 string at either end.
  static const _chunkBytes = 32 * 1024;

  Future<void> _sendRecords(
      LivePeer peer, String chatId, List<ChatRecord> records) async {
    if (records.isEmpty) return;
    await peer.send(SyncMessage.recordAppend(chatId: chatId, records: records));
  }

  // ------------------------------------------------------------ resources

  /// The synthetic resource namespace an artifact travels under: one zip of
  /// the artifact's files, requested like any attachment and opened on the
  /// asking side by that platform's own viewer. The `/` is what keeps the
  /// name out of `resourceName`'s alphabet — a user attachment can never
  /// land here by accident.
  static const _artifactPrefix = ".artifacts/";

  /// An artifact of a mirrored chat: from the cache, or as one zip over the
  /// ordinary resource channel and into it. Same steps as [resourceBytes].
  @override
  Future<Uint8List?> artifactBytes(String chatId, String artifactId) =>
      resourceBytes(chatId, "$_artifactPrefix$artifactId");

  /// The synthetic name the chat's `PLAN.md` is asked for under: the `/`
  /// keeps it out of `resourceName`'s alphabet, as for an artifact. An older
  /// home device reads it as an attachment it does not have and answers
  /// null.
  static const _planResource = ".plan/PLAN.md";

  /// A mirrored chat's plan, fetched fresh rather than cached: it changes as
  /// the turn works through it, and the caller asks again when it might have.
  Future<String?> planText(String chatId) async {
    final bytes = await fetchResource(chatId, _planResource);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// Streams a resource to a subscribing peer, base64 inside control
  /// frames — correlation stays trivial and every frame rides the same AEAD
  /// as the rest of the traffic. Binary framing can come later without a
  /// protocol change: the type byte already separates the streams. A name
  /// under [_artifactPrefix] is an artifact rather than an attachment, and
  /// goes out as one zip of its files; [_planResource] is the chat's plan.
  Future<void> _serveResource(
      LivePeer peer, String id, String chatId, String resource) async {
    Uint8List? bytes;
    if (peer.subscriptions.contains(chatId)) {
      bytes = switch (resource) {
        _planResource => switch (await _repo?.readPlan(chatId)) {
            final plan? => utf8.encode(plan),
            null => null,
          },
        _ when resource.startsWith(_artifactPrefix) => await _repo
            ?.readArtifactZip(chatId, resource.substring(_artifactPrefix.length)),
        _ => await _repo?.readResource(chatId, resource),
      };
    }
    await _sendChunks(peer, id, bytes);
  }

  /// [bytes] as a run of chunks under [id]; none is one empty final chunk.
  Future<void> _sendChunks(LivePeer peer, String id, Uint8List? bytes) async {
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

  void _collectResourceChunk(
      LivePeer peer, String id, String bytesB64, bool done) {
    final transfer = _pendingResources[id];
    if (transfer == null || transfer.completer.isCompleted) return;
    if (transfer.deviceId != peer.deviceId) {
      logFailure("sync", "resource chunk $id from ${peer.deviceId}, not the peer asked");
      return;
    }
    transfer.buffer.add(base64Decode(bytesB64));
    if (!done) return;
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
    for (final echo in _echoes) {
      if (echo.peerId == deviceId && !echo.done.isCompleted) echo.done.complete(null);
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
        // The book's name — a rename landed in the status already; the
        // connection's snapshot is the fallback for what has gone missing.
        name: _peers.states.value[deviceId]?.name ??
            live?.deviceName ??
            deviceId,
        status: PeerStatus.offline);
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
          // The name is the book's, read at rebuild: a rename is one write
          // through [PeerState], and every row it names follows at the next
          // rebuild it lands in. The mirror's creation name is the fallback
          // for a device that is not in the book.
          deviceName:
              _peers.states.value[mirror.peerId]?.name ?? mirror.deviceName,
          state: mirror.state,
          online: _peers.hasLive(mirror.peerId),
          omada: _omadaProjects[mirror.peerId]
                  ?.contains(mirror.state.project) ??
              false,
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
    await _subAgentSub?.cancel();
    // Before the mirror state below: closing a peer runs [_peerGone], which
    // reads it. [_mirrorUpdates] closes after both, and [_touch]'s microtask
    // is why that one is guarded rather than ordered.
    await _peers.dispose();
    _mirrors.clear();
    byteCache.dispose();
    _desired.clear();
    _desiredSubAgents.clear();
    remotes.value = const [];
    await _mirrorUpdates.close();
    await _subAgentUpdates.close();
    for (final transfer in _pendingResources.values) {
      if (!transfer.completer.isCompleted) transfer.completer.complete(null);
    }
    _pendingResources.clear();
    await _signaling.dispose();
  }

  /// What [deviceId] is filed under here, from now on. A rename is local to
  /// this device's address book, like every name in it: the other device
  /// keeps what it calls this one until renamed there too.
  Future<void> rename(String deviceId, String name) async {
    await registry.rename(deviceId, name);
    // The row is the book's; the mirrors' Remotes rows derive theirs from
    // that same PeerState at rebuild.
    _peers.renamed(deviceId, name);
    _rebuildRemotes();
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
    deviceProjects.value = {...deviceProjects.value}..remove(deviceId);
    _rebuildRemotes();
    unawaited(_peers.refresh());
  }

}

/// One resource transfer in flight: chunks accumulate until `done`.
class _ResourceTransfer {
  _ResourceTransfer(this.deviceId);

  /// The peer asked: ids are a counter, so any other peer could name one.
  final String deviceId;
  final completer = Completer<Uint8List?>();
  final buffer = BytesBuilder(copy: false);
}
