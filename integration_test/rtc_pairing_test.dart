import "dart:io";
import "dart:typed_data";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/sync/channel.dart";
import "package:agent_chat/data/sync/rtc_channel.dart";
import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:integration_test/integration_test.dart";

import "../test/fakes.dart";

/// The one layer `flutter test` cannot reach: `flutter_webrtc` is a native
/// plugin, so a peer connection needs a real engine with the plugin
/// registered. Everything above it is proven on a loopback channel in
/// `test/data/sync/sync_hub_pair_test.dart`; this is the wire underneath.
///
/// Both peers live in this one process, connecting to each other over
/// loopback ICE. That does not prove anything about NAT or TURN — nothing
/// running on one machine can — but it does prove the SDP dance, the data
/// channel, and the whole hub stack riding on a real one.
///
/// Run it against a desktop:
///
///     flutter test -d linux integration_test/rtc_pairing_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async =>
      tempDir = await Directory.systemTemp.createTemp("rtc-pair-test"));
  tearDown(() => tempDir.delete(recursive: true));

  /// Two connected `ByteChannel`s over one real peer connection. The SDP
  /// crosses in-process: which rendezvous carried it is the signaling
  /// layer's business, and has its own tests over real sockets.
  Future<(ByteChannel, ByteChannel, Future<void> Function())> connected() async {
    // No STUN: both ends are on this machine, and asking Google about it only
    // adds seconds to a test that would work without an internet connection.
    final offerer = await RtcLink.create(iceServers: const []);
    final answerer = await RtcLink.create(iceServers: const []);
    final offer = await offerer.offer();
    final answer = await answerer.answer(offer);
    await offerer.acceptAnswer(answer);
    final channels = await Future.wait([offerer.open(), answerer.open()]);
    return (
      channels[0],
      channels[1],
      () async {
        await offerer.close();
        await answerer.close();
      }
    );
  }

  testWidgets("a real data channel carries bytes both ways", (_) async {
    final (a, b, dispose) = await connected();
    addTearDown(dispose);

    final atB = ChannelReader(b);
    final atA = ChannelReader(a);
    await a.send(Uint8List.fromList([1, 2, 3]));
    expect(await atB.next().timeout(const Duration(seconds: 10)), [1, 2, 3]);

    await b.send(Uint8List.fromList([4, 5]));
    expect(await atA.next().timeout(const Duration(seconds: 10)), [4, 5]);
  });

  testWidgets("a message larger than one frame arrives whole", (_) async {
    final (a, b, dispose) = await connected();
    addTearDown(dispose);

    final atB = ChannelReader(b);
    // SCTP preserves message boundaries, which is what the framing above
    // this line assumes: one send is one receive, however big.
    final big = Uint8List.fromList(
        List.generate(60 * 1024, (i) => i % 251));
    await a.send(big);

    expect(await atB.next().timeout(const Duration(seconds: 20)), big);
  });

  testWidgets("two devices pair and mirror a chat over it", (_) async {
    final (a, b, dispose) = await connected();
    addTearDown(dispose);

    final home = await _Device.create("${tempDir.path}/home");
    final away = await _Device.create("${tempDir.path}/away");
    addTearDown(home.hub.dispose);
    addTearDown(away.hub.dispose);

    final now = DateTime.now();
    final state = ChatState(
        id: "chat-1", title: "Home chat", createdAt: now, updatedAt: now);
    await home.store.saveState(state);
    await home.store.append(state.id, [
      ChatRecord.message(id: "m1", role: MessageRole.user, createdAt: now),
    ]);

    final pairing = Future.wait([
      home.hub.establishForTest(link: a, weOffered: true, psk: "test-psk"),
      away.hub.establishForTest(link: b, weOffered: false, psk: "test-psk"),
    ]);
    await _until(() =>
        home.hub.pairing.value?.stage == PairingStage.confirming &&
        away.hub.pairing.value?.stage == PairingStage.confirming);
    // Both screens show the same six characters, which is the whole point of
    // showing them: a machine in the middle could not make them agree.
    expect(home.hub.pairing.value!.sas, away.hub.pairing.value!.sas);
    home.hub.confirmPairing(true);
    away.hub.confirmPairing(true);
    await pairing;

    away.hub.followChat(state.id);
    await _until(() => away.hub.mirror(state.id)?.records.isNotEmpty ?? false);

    expect(away.hub.mirror(state.id)!.state.title, "Home chat");
    expect(await home.registry.list(), hasLength(1));

    // And it keeps up: a record written after pairing crosses the same wire.
    await home.repo.append(state.id,
        [ChatRecord.turnEnd(messageId: "m1", reason: TurnEnd.done)]);
    await _until(() => away.hub.mirror(state.id)!.records.length == 2);
  });
}

class _Device {
  _Device(this.hub, this.registry, this.store, this.repo);

  static Future<_Device> create(String dir) async {
    final config = await AppConfig.load(fileSystemIo, dir);
    final registry = FakeDeviceRegistry();
    final store = FakeChatStore();
    final repo = ChatRepository(store, FakeBackend(), AppSettings.new, config);
    final hub = SyncHub(
      identity: await SyncIdentity.load(FakeSecretStore()),
      registry: registry,
      config: config,
      settings: AppSettings.new,
      lanSignaling: () => null,
    );
    hub.attach(repo);
    return _Device(hub, registry, store, repo);
  }

  final SyncHub hub;
  final FakeDeviceRegistry registry;
  final FakeChatStore store;
  final ChatRepository repo;
}

/// Real time, since everything under here is a real socket. Generous: ICE on
/// loopback is fast, but a first peer connection loads a native library.
Future<void> _until(bool Function() done,
    {Duration limit = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(limit);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail("condition not met within $limit");
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
