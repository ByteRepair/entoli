import "dart:async";
import "dart:io" show Directory;
import "dart:typed_data";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/sync/channel.dart";
import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/secret_store.dart";
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:agent_chat/providers.dart" show syncHubProvider;
import "package:agent_chat/ui/chat/mirror_controller.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart" show FakeBackend, FakeChatStore;

/// Two real SyncHubs over a loopback channel pair — everything from the
/// handshake up runs for real; only the transport under the data channel is
/// stood in for. This is where Phase 2's mirroring is proven end to end:
/// welcome, snapshot, appends, resources, offline, and resume-from-line.
void main() {
  late Directory tempDir;
  late _Device home;
  late _Device away;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp("sync-pair-test");
    home = await _Device.create("${tempDir.path}/home");
    away = await _Device.create("${tempDir.path}/away");
  });

  tearDown(() async {
    await home.hub.dispose();
    await away.hub.dispose();
    await tempDir.delete(recursive: true);
  });

  /// Establishes both ends of one pairing. First contact, so both stop at
  /// the codes-matched gate and are confirmed by hand.
  Future<void> pair(ByteChannel homeLink, ByteChannel awayLink,
      {String? knownToHome, String? knownToAway}) async {
    final a = home.hub.establishForTest(
      link: homeLink,
      weOffered: true,
      psk: "test-psk",
      knownDeviceId: knownToHome,
    );
    final b = away.hub.establishForTest(
      link: awayLink,
      weOffered: false,
      psk: "test-psk",
      knownDeviceId: knownToAway,
    );
    if (knownToHome == null || knownToAway == null) {
      await eventually(
          () =>
              home.hub.pairing.value?.stage == PairingStage.confirming &&
              away.hub.pairing.value?.stage == PairingStage.confirming);
      home.hub.confirmPairing(true);
      away.hub.confirmPairing(true);
    }
    await Future.wait([a, b]);
  }

  test("pairing files each device in the other's registry", () async {
    final links = loopbackPair();
    await pair(links.$1, links.$2);

    final listed = await home.registry.list();
    expect(listed, hasLength(1));
    expect(listed.single.name, away.hub.deviceName);
    expect(home.hub.peers.value.values.single.status, PeerStatus.online);
  });

  test("a chat on the home device mirrors with its records", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);

    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    final mirror = away.hub.mirror(state.id)!;
    expect(mirror.records.length, home.store.records(state.id).length);
    expect(mirror.totalLines, mirror.records.length);
    expect(mirror.deviceName, home.hub.deviceName);
    expect(away.hub.isChatOnline(state.id), isTrue);

    final entry =
        away.hub.remotes.value.singleWhere((e) => e.chatId == state.id);
    expect(entry.deviceId, home.identity.id);
    expect(entry.online, isTrue);
  });

  test("appends on the home device reach the mirror", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    final before = away.hub.mirror(state.id)!.records.length;
    await home.repo.append(state.id,
        [ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done)]);
    await eventually(() =>
        away.hub.mirror(state.id)!.records.length > before);
  });

  test("a retitle arrives as a state diff", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    await home.repo.retitle(
        await home.repo.openChat(state.id).then((c) => c.state), "Renamed");
    await eventually(
        () => away.hub.mirror(state.id)?.state.title == "Renamed");
  });

  test("deleting the home chat drops the mirror but not the row's owner",
      () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    await home.repo.deleteChat(state.id);
    await eventually(() => away.hub.mirror(state.id) == null);
  });

  test("an attachment crosses as base64 chunks and reassembles", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    // Large enough to need more than one chunk at the wire's 48KB frame.
    final bytes = Uint8List.fromList(
        List.generate(120 * 1024, (i) => i % 251));
    final resource =
        await home.store.saveResource(state.id, "photo.bin", bytes);

    final fetched = await away.hub.fetchResource(state.id, resource);
    expect(fetched, equals(bytes));
  });

  test("a fetch for an unknown resource answers null, not a hang", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    expect(await away.hub.fetchResource(state.id, "gone.bin"), isNull);
  });

  test("going offline keeps the stale snapshot and says so", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    await links.$1.close();
    await links.$2.close();
    await eventually(() =>
        away.hub.peers.value[home.identity.id]?.status == PeerStatus.offline);

    // The point of keeping it: what was read stays readable.
    expect(away.hub.mirror(state.id), isNotNull);
    expect(away.hub.remotes.value.single.online, isFalse);
  });

  test("reconnecting resumes from the line count, not a second full log",
      () async {
    final state = _seedChat(home);
    var links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);
    final heldBefore = away.hub.mirror(state.id)!.records.length;

    await links.$1.close();
    await links.$2.close();
    await eventually(() =>
        away.hub.peers.value[home.identity.id]?.status == PeerStatus.offline);

    // Said while the peer was gone.
    await home.repo.append(state.id,
        [ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done)]);

    links = loopbackPair();
    await pair(links.$1, links.$2,
        knownToHome: away.identity.id, knownToAway: home.identity.id);
    // followChat is still desired, so the reconnecting welcome re-opens it.
    await eventually(() =>
        away.hub.mirror(state.id)!.records.length ==
        home.store.records(state.id).length);

    final mirror = away.hub.mirror(state.id)!;
    expect(mirror.records.length, heldBefore + 1);
    expect(mirror.totalLines, mirror.records.length);
    // No duplicate of what the first session already carried.
    expect(mirror.records.whereType<MessageRecord>().map((m) => m.id),
        ["m1", "r1"]);
  });

  test("mirrored bytes are dropped with the mirror they belong to", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);
    away.hub.byteCache.put(state.id, "photo.bin", Uint8List(8));

    await home.repo.deleteChat(state.id);
    await eventually(() => away.hub.mirror(state.id) == null);

    expect(away.hub.byteCache.get(state.id, "photo.bin"), isNull);
  });

  test("revoking a device takes its mirrors and its row with it", () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);

    await away.hub.revoke(home.identity.id);

    expect(away.hub.mirror(state.id), isNull);
    expect(away.hub.remotes.value, isEmpty);
    expect(away.hub.peers.value, isEmpty);
    expect(await away.registry.list(), isEmpty);
  });

  /// The controller the read-only page is built on, over a real mirror. The
  /// page's own tests fake this out; what the wire actually resolves to is
  /// here, where there is a peer to lose.
  test("the mirror controller replays the log, and says when it went stale",
      () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);

    final container = ProviderContainer(
        overrides: [syncHubProvider.overrideWithValue(away.hub)]);
    addTearDown(container.dispose);
    final provider = mirrorChatControllerProvider(state.id);

    // Listened, not read: a provider nobody holds is disposed again, and
    // disposing this one unfollows the chat.
    container.listen(provider, (_, _) {});
    await eventually(() => container.read(provider).chat != null);
    expect(container.read(provider).chat!.messages, hasLength(2));
    expect(container.read(provider).status, isNull);

    await links.$1.close();
    await links.$2.close();
    await eventually(() => container.read(provider).status != null);
    expect(container.read(provider).status, contains("offline"));
    // The snapshot is what stays readable.
    expect(container.read(provider).chat!.messages, hasLength(2));
  });
}

// ------------------------------------------------------------------ harness

class _Device {
  _Device(this.identity, this.hub, this.registry, this.store, this.repo);

  static Future<_Device> create(String dir) async {
    final config = await AppConfig.load(fileSystemIo, dir);
    final identity = await SyncIdentity.load(_MemorySecrets());
    final registry = _MemoryRegistry();
    final store = FakeChatStore();
    final repo = ChatRepository(store, FakeBackend(), AppSettings.new, config);
    final hub = SyncHub(
      identity: identity,
      registry: registry,
      config: config,
      settings: AppSettings.new,
      lanSignaling: () => null,
    );
    hub.attach(repo);
    return _Device(identity, hub, registry, store, repo);
  }

  final SyncIdentity identity;
  final SyncHub hub;
  final DeviceRegistry registry;
  final FakeChatStore store;
  final ChatRepository repo;
}

ChatState _seedChat(_Device device) {
  final now = DateTime.now();
  final state = ChatState(
      id: "chat-1", title: "Home chat", createdAt: now, updatedAt: now);
  device.store.saveState(state);
  device.store.append(state.id, [
    ChatRecord.message(id: "m1", role: MessageRole.user, createdAt: now),
    ChatRecord.message(
        id: "r1", role: MessageRole.assistant, createdAt: now),
  ]);
  return state;
}

(ByteChannel, ByteChannel) loopbackPair() {
  final a = _Loopback();
  final b = _Loopback();
  a.other = b;
  b.other = a;
  return (a, b);
}

class _Loopback implements ByteChannel {
  _Loopback? other;
  final _incoming = StreamController<Uint8List>.broadcast();
  var _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    if (_closed) throw StateError("loopback closed");
    final peer = other!;
    if (peer._closed) throw StateError("peer closed");
    peer._incoming.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}

class _MemorySecrets implements SecretStore {
  final _items = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => _items[key];

  @override
  Future<void> write(String key, Uint8List value) async => _items[key] = value;

  @override
  Future<void> delete(String key) async => _items.remove(key);

  @override
  bool get encrypted => false;
}

class _MemoryRegistry implements DeviceRegistry {
  final _devices = <String, PairedDevice>{};
  final _secrets = <String, String>{};

  @override
  Future<List<PairedDevice>> list() async => _devices.values.toList();

  @override
  Future<PairedDevice?> byId(String id) async => _devices[id];

  @override
  Future<void> add(PairedDevice device) async => _devices[device.id] = device;

  @override
  Future<void> remove(String id) async => _devices.remove(id);

  @override
  Future<void> markSeen(String id, {String? address}) async {}

  @override
  Future<String?> pairingSecret(String id) async => _secrets[id];

  @override
  Future<void> setPairingSecret(String id, String secret) async =>
      _secrets[id] = secret;
}

Future<void> eventually(bool Function() done,
    {Duration limit = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      fail("condition not met within $limit");
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
