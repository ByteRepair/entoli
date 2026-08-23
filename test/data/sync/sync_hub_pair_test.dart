import "dart:io" show Directory;
import "dart:typed_data";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/sync/channel.dart";
import "package:agent_chat/data/sync/handshake.dart" show HandshakeException;
import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/chat_store.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:agent_chat/domain/sync/protocol.dart";
import "package:agent_chat/providers.dart" show syncHubProvider;
import "package:agent_chat/ui/chat/mirror_controller.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart"
    show FakeBackend, FakeChatStore, FakeDeviceRegistry, loopbackPair;
import "../../harness.dart";

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
  Future<void> pairing(_Device offers, _Device joins, ByteChannel offerLink,
      ByteChannel joinLink,
      {String? knownToOfferer,
      String? knownToJoiner,
      // A real one by default. A hand-written stand-in was what hid the
      // padding bug: 32 bytes of base64url with the `=` stripped is 43
      // characters, and every short literal anyone reached for happened to
      // be a length `base64Decode` would accept.
      String? psk}) async {
    psk ??= generatePsk();
    final a = offers.hub.establishForTest(
      link: offerLink,
      weOffered: true,
      psk: psk,
      knownDeviceId: knownToOfferer,
    );
    final b = joins.hub.establishForTest(
      link: joinLink,
      weOffered: false,
      psk: psk,
      knownDeviceId: knownToJoiner,
    );
    if (knownToOfferer == null || knownToJoiner == null) {
      await eventually(
          () =>
              offers.hub.pairing.value?.stage == PairingStage.confirming &&
              joins.hub.pairing.value?.stage == PairingStage.confirming);
      offers.hub.confirmPairing(true);
      joins.hub.confirmPairing(true);
    }
    await Future.wait([a, b]);
  }

  Future<void> pair(ByteChannel homeLink, ByteChannel awayLink,
          {String? knownToHome, String? knownToAway}) =>
      pairing(home, away, homeLink, awayLink,
          knownToOfferer: knownToHome, knownToJoiner: knownToAway);

  /// A chat on the home device, mirrored on [away] and ready to be driven.
  Future<ChatState> mirrored() async {
    final state = _seedChat(home);
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);
    return state;
  }

  test("a real pairing secret is not a valid base64 length", () {
    // The property the bug turned on, pinned so nobody 'tidies' the padding
    // strip in `generatePsk` back out from under the handshake.
    final psk = generatePsk();
    expect(psk, hasLength(43));
    expect(psk.length % 4, isNot(0));
    expect(psk, isNot(contains("=")));
  });

  /// A data channel refuses a message past its negotiated maximum, and a
  /// conversation of any length is far past it — the chats this was first run
  /// against were 74KB, 256KB and 485KB of `conv.jsonl`, and every one of
  /// them mirrored as an empty chat. A loopback carries any size, so what is
  /// asserted is the size of what goes over it.
  test("a log too big for one message crosses in pages", () async {
    final now = DateTime.now();
    final state = ChatState(
        id: "big", title: "Long chat", createdAt: now, updatedAt: now);
    await home.store.saveState(state);
    await home.store.append(state.id, [
      for (var i = 0; i < 200; i++)
        ChatRecord.part(
          messageId: "m$i",
          index: 0,
          part: TextPart(text: "x" * 2000),
        ),
    ]);

    final links = loopbackPair();
    final sent = <int>[];
    links.$1.watchSends(sent.add);
    await pair(links.$1, links.$2);
    away.hub.followChat(state.id);
    await eventually(() =>
        away.hub.mirror(state.id)?.records.length ==
        (home.store as FakeChatStore).records(state.id).length);

    final mirror = away.hub.mirror(state.id)!;
    expect(mirror.totalLines, mirror.records.length);
    // Well over 400KB of records, so it cannot have been one message.
    expect(sent.reduce((a, b) => a > b ? a : b), lessThan(64 * 1024));
  });

  /// Everything above runs on a `FakeChatStore`, which answers from memory.
  /// The app runs on `FileChatStore`, and `_serveOpen` reads a chat's head,
  /// its meta and its log through three separate store calls — a path no test
  /// took until this one.
  test("a chat on a real store mirrors with its records", () async {
    final onDisk = await _Device.create("${tempDir.path}/disk",
        store: FileChatStore(await AppConfig.load(
            fileSystemIo, "${tempDir.path}/disk")));
    addTearDown(onDisk.hub.dispose);

    final chat = Chat(
      state: ChatState(
        id: "on-disk",
        title: "Written down",
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      messages: [
        Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: DateTime.utc(2026),
          parts: [TextPart(text: "said out loud")],
        ),
      ],
    );
    await writeChatTo(onDisk.store, chat);

    final links = loopbackPair();
    await pairing(onDisk, away, links.$1, links.$2);
    away.hub.followChat("on-disk");
    await eventually(() => away.hub.mirror("on-disk") != null);
    await eventually(() => away.hub.mirror("on-disk")!.records.isNotEmpty);

    final mirrored = chatFrom(
        away.hub.mirror("on-disk")!.state, away.hub.mirror("on-disk")!.records);
    expect(mirrored.state.title, "Written down");
    expect(mirrored.messages.single.plainText, "said out loud");
  });

  /// The hub is built before the container it reads from, so the repository
  /// has to be handed to it afterwards — and until it is, a device pairs
  /// happily and serves nothing: no welcome, no chat list, no records. That
  /// is what shipped, because every test called `attach` in its own harness
  /// and `main` called it nowhere. `main` itself is not reachable from a test
  /// (see `test/CLAUDE.md`), so what is pinned here is the symptom, loudly
  /// enough to recognise if it comes back.
  test("a hub with no repository serves nothing", () async {
    final config = tempConfig();
    final hub = await testSyncHub(config);
    addTearDown(hub.dispose);

    expect(hub.isServing, isFalse);
    hub.attach(home.repo);
    expect(hub.isServing, isTrue);
  });

  /// Two humans do not press Confirm at the same instant, and the side that
  /// pressed first starts sending the moment it has. Confirming in one
  /// synchronous block — which every test here did — leaves a gap of
  /// microtasks; a real pairing leaves one of seconds, and everything the
  /// first side sent into it was dropped by the second.
  test("a pairing survives one side confirming long before the other",
      () async {
    final state = _seedChat(home);
    final links = loopbackPair();
    final psk = generatePsk();
    final a = home.hub.establishForTest(
        link: links.$1, weOffered: true, psk: psk);
    final b = away.hub.establishForTest(
        link: links.$2, weOffered: false, psk: psk);
    await eventually(() =>
        home.hub.pairing.value?.stage == PairingStage.confirming &&
        away.hub.pairing.value?.stage == PairingStage.confirming);
    // Both screens show the same code, which is the whole point of showing it.
    expect(home.hub.pairing.value!.sas, away.hub.pairing.value!.sas);

    home.hub.confirmPairing(true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    away.hub.confirmPairing(true);
    await Future.wait([a, b]);

    away.hub.followChat(state.id);
    await eventually(() => away.hub.mirror(state.id) != null);
    expect(away.hub.peers.value[home.identity.id]?.status, PeerStatus.online);
  });

  test("a pairing refused after the other side confirmed leaves nothing",
      () async {
    _seedChat(home);
    final links = loopbackPair();
    final psk = generatePsk();
    final a = home.hub.establishForTest(
        link: links.$1, weOffered: true, psk: psk);
    final b = away.hub.establishForTest(
        link: links.$2, weOffered: false, psk: psk);
    await eventually(() =>
        away.hub.pairing.value?.stage == PairingStage.confirming);

    // The other side has already sent its welcome by the time this one says
    // no, so what it sent must not have been applied.
    home.hub.confirmPairing(true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    away.hub.confirmPairing(false);
    await expectLater(b, throwsA(isA<HandshakeException>()));
    await a.catchError((_) {});

    expect(away.hub.remotes.value, isEmpty);
    expect(await away.registry.list(), isEmpty);
  });

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
    expect(mirror.records.length, (home.store as FakeChatStore).records(state.id).length);
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
        (home.store as FakeChatStore).records(state.id).length);

    final mirror = away.hub.mirror(state.id)!;
    expect(mirror.records.length, heldBefore + 1);
    expect(mirror.totalLines, mirror.records.length);
    // No duplicate of what the first session already carried.
    expect(mirror.records.whereType<MessageRecord>().map((m) => m.id),
        ["m1", "r1"]);
  });

  test("a chat made after pairing appears in the mirror's list", () async {
    final links = loopbackPair();
    await pair(links.$1, links.$2);
    await eventually(() => away.hub.peers.value.isNotEmpty);

    final state = _seedChat(home);
    await home.repo.saveState(state);
    await eventually(() =>
        away.hub.remotes.value.any((e) => e.chatId == state.id));

    expect(away.hub.remotes.value.single.state.title, "Home chat");
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

  /// Control and teleport, over the same two real hubs. What is being proven
  /// is that the lock is the *home* device's answer and that nothing runs
  /// without it — a mirror drawing a composer is a consequence, not a
  /// permission.
  group("control", () {
    late _Turns turns;

    setUp(() => home.hub.remoteTurns = turns = _Turns());

    test("asking for a free chat is granted and told to everyone", () async {
      final state = await mirrored();

      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));

      expect(home.hub.heldBy(state.id), away.identity.id);
      expect(home.hub.drivenChats.value[state.id], away.hub.deviceName);
      expect(away.hub.mirror(state.id)!.controlHolder, away.identity.id);
    });

    test("a second device is refused, and hears who has it", () async {
      final state = await mirrored();
      final other = await _Device.create("${tempDir.path}/other");
      addTearDown(other.hub.dispose);
      final links = loopbackPair();
      await pairing(home, other, links.$1, links.$2, psk: generatePsk());
      other.hub.followChat(state.id);
      await eventually(() => other.hub.mirror(state.id) != null);

      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));
      await other.hub.requestControl(state.id);
      await eventually(
          () => other.hub.mirror(state.id)!.controlHolder != null);

      expect(other.hub.holdsControl(state.id), isFalse);
      expect(other.hub.mirror(state.id)!.controlHolder, away.identity.id);
      expect(home.hub.heldBy(state.id), away.identity.id);
    });

    test("the holder's prompt runs on the home device", () async {
      final state = await mirrored();
      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));

      await away.hub.sendRemotePrompt(state.id, "do the thing");
      await eventually(() => turns.prompts.isNotEmpty);

      expect(turns.prompts.single, (state.id, "do the thing"));
    });

    test("every verb reaches the home device's own controller", () async {
      final state = await mirrored();
      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));

      await away.hub.resumeRemote(state.id);
      await away.hub.respondRemoteApproval(state.id, "a1", true);
      await away.hub.answerRemoteQuestions(state.id, "q1", ["yes"]);
      await away.hub.abortRemote(state.id);
      await eventually(() => turns.aborted.isNotEmpty);

      expect(turns.resumed, [state.id]);
      expect(turns.approved, [(state.id, "a1", true)]);
      expect(turns.aborted, [state.id]);
      // Compared field by field: the answers arrive as freezed's own
      // unmodifiable list, which is not `==` to a literal one.
      expect(turns.answered.single.$1, state.id);
      expect(turns.answered.single.$2, "q1");
      expect(turns.answered.single.$3, ["yes"]);
    });

    test("a prompt from a device holding nothing is dropped", () async {
      final state = await mirrored();

      // Past the local guard, which is about not shouting into the void
      // rather than about permission: the home device is what refuses.
      await away.hub.sendForTest(
          state.id, SyncMessage.promptSend(chatId: state.id, text: "hi"));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(turns.prompts, isEmpty);
    });

    test("releasing hands it back", () async {
      final state = await mirrored();
      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));

      await away.hub.releaseControl(state.id);
      await eventually(() => home.hub.heldBy(state.id) == null);

      await eventually(
          () => away.hub.mirror(state.id)!.controlHolder == null);
      expect(home.hub.drivenChats.value, isEmpty);
    });

    test("a lock does not outlive the connection that took it", () async {
      final state = _seedChat(home);
      final links = loopbackPair();
      await pair(links.$1, links.$2);
      away.hub.followChat(state.id);
      await eventually(() => away.hub.mirror(state.id) != null);
      await away.hub.requestControl(state.id);
      await eventually(() => away.hub.holdsControl(state.id));

      await links.$1.close();
      await links.$2.close();

      await eventually(() => home.hub.heldBy(state.id) == null);
      expect(home.hub.drivenChats.value, isEmpty);
    });

    test("the turn the home device is running reaches the mirror", () async {
      final state = await mirrored();
      await eventually(() => home.hub.servedChats.value.contains(state.id));

      home.hub.publishTurn(
        state.id,
        running: true,
        approvals: const [
          ToolApproval(id: "a1", toolName: "bash", argumentsText: "ls"),
        ],
        asks: const [SyncAsk(id: "q1", argumentsJson: "{}")],
        status: "Thinking",
      );
      await eventually(() => away.hub.mirror(state.id)!.running);

      final mirror = away.hub.mirror(state.id)!;
      expect(mirror.approvals.single.argumentsText, "ls");
      expect(mirror.asks.single.id, "q1");
      expect(mirror.status, "Thinking");
    });
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

/// The home device's end of a teleported turn, with no controller under it.
/// What the real one does with these is `RemoteTurnDriver`'s; what is being
/// checked here is that they arrive at all, and only from the holder.
class _Turns implements RemoteTurns {
  final prompts = <(String, String)>[];
  final resumed = <String>[];
  final aborted = <String>[];
  final approved = <(String, String, bool)>[];
  final answered = <(String, String, List<String?>)>[];

  @override
  void prompt(String chatId, String text) => prompts.add((chatId, text));

  @override
  void resume(String chatId) => resumed.add(chatId);

  @override
  void abort(String chatId) => aborted.add(chatId);

  @override
  void approve(String chatId, String approvalId, bool allow) =>
      approved.add((chatId, approvalId, allow));

  @override
  void answer(String chatId, String requestId, List<String?> answers) =>
      answered.add((chatId, requestId, answers));
}

class _Device {
  _Device(this.identity, this.hub, this.registry, this.store, this.repo);

  static Future<_Device> create(String dir, {ChatStore? store}) async {
    final config = await AppConfig.load(fileSystemIo, dir);
    final registry = FakeDeviceRegistry();
    final chats = store ?? FakeChatStore();
    final repo = ChatRepository(chats, FakeBackend(), AppSettings.new, config);
    final hub = await testSyncHub(config, devices: registry);
    hub.attach(repo);
    return _Device(hub.identity, hub, registry, chats, repo);
  }

  final SyncIdentity identity;
  final SyncHub hub;
  final DeviceRegistry registry;
  final ChatStore store;
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
