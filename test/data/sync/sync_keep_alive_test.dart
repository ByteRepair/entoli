import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/sync/sync_keep_alive.dart";
import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/background_work.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "../../fakes.dart";
import "../../harness.dart";

void main() {
  late SyncHub hub;
  late FakeBackgroundWork work;
  late SyncKeepAlive keepAlive;
  late bool setting;

  setUp(() async {
    hub = await testSyncHub();
    work = FakeBackgroundWork();
    setting = true;
    keepAlive = SyncKeepAlive(hub, work, keepAlive: () => setting);
  });

  tearDown(() async {
    keepAlive.dispose();
    await hub.dispose();
  });

  /// Mark a paired device online, the way `_establish` files a peer in.
  void connected(String id, String name, PeerStatus status) {
    hub.peers.value = {
      "gone": PeerState(
          deviceId: "gone", name: "Offline Device", status: PeerStatus.offline),
      id: PeerState(deviceId: id, name: name, status: status),
    };
  }

  test("a connected device is reported, by name", () async {
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();

    expect(work.synced.single, isNotNull);
    expect(work.synced.single!.count, 1);
    expect(work.synced.single!.devices, "Laptop");
  });

  test("a connecting one counts — the hold has to cover the dial", () async {
    connected("d1", "Laptop", PeerStatus.connecting);
    await pumpEventQueue();

    expect(work.synced.single, isNotNull);
  });

  test("going offline releases the hold", () async {
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();

    connected("d1", "Laptop", PeerStatus.offline);
    await pumpEventQueue();

    expect(work.synced.last, isNull);
  });

  test("the setting off is the same answer as nobody connected", () async {
    setting = false;
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();

    expect(work.synced, everyElement(isNull));
  });

  test("the switch off mid-connection releases at once", () async {
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();
    expect(work.synced.last, isNotNull);

    setting = false;
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();

    expect(work.synced.last, isNull);
  });

  test("the notification's Disconnect closes every connected peer", () async {
    connected("d1", "Laptop", PeerStatus.online);
    await pumpEventQueue();

    work.stop(BackgroundJob.sync);
    await pumpEventQueue();

    expect(hub.peers.value["d1"]!.status, PeerStatus.offline);
    // And that is what releases the service: the emptied list.
    expect(work.synced.last, isNull);
  });

  group("the setting", () {
    late Directory tmp;
    late AppConfig config;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync("sync_keep_alive_test_");
      config = AppConfig.forDirectory(tmp.path, fileSystemIo);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test("survives save and load, and off writes nothing", () async {
      await AppSettings(syncKeepAlive: true).save(config);
      expect(AppSettings.load(config).syncKeepAlive, isTrue);

      // Written only when on: a file that predates the switch says nothing
      // and gets the off default.
      final json = jsonDecode(File(config.settingsFile).readAsStringSync())
          as Map<String, dynamic>;
      expect(json.containsKey("syncKeepAlive"), isTrue);

      await AppSettings().save(config);
      expect(AppSettings.load(config).syncKeepAlive, isFalse);
      final quiet = jsonDecode(File(config.settingsFile).readAsStringSync())
          as Map<String, dynamic>;
      expect(quiet.containsKey("syncKeepAlive"), isFalse);
    });
  });
}