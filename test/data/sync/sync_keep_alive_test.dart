import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/sync_keep_alive.dart";
import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/background_work.dart";

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

  /// Mark a paired device online, the way `_establish` files a peer in. The
  /// offline entry beside it is every change that does not touch the
  /// connected set — the churn the keep-alive is meant to answer free.
  void connected(String id, String name, PeerStatus status) {
    hub.peers.value = {
      "gone": PeerState(
          deviceId: "gone", name: "Offline Device", status: PeerStatus.offline),
      id: PeerState(deviceId: id, name: name, status: status),
    };
  }

  test("a peer that is not offline holds the service, by name", () async {
    connected("d1", "Laptop", PeerStatus.online);
    expect(work.synced.single, isNotNull);
    expect(work.synced.single!.names, ["Laptop"]);

    // The dial, too: connecting is part of what has to be covered.
    connected("d2", "Phone", PeerStatus.connecting);
    expect(work.synced, hasLength(2));
    expect(work.synced.last, isNotNull);
  });

  test("going offline releases the hold", () async {
    connected("d1", "Laptop", PeerStatus.online);

    connected("d1", "Laptop", PeerStatus.offline);

    expect(work.synced.last, isNull);
  });

  test("the setting off is the same answer as nobody connected", () async {
    setting = false;
    connected("d1", "Laptop", PeerStatus.online);

    expect(work.synced, everyElement(isNull));
  });

  test("the switch off mid-connection releases at once", () async {
    connected("d1", "Laptop", PeerStatus.online);
    expect(work.synced.last, isNotNull);

    setting = false;
    await keepAlive.refresh();

    expect(work.synced.last, isNull);
  });

  test("an unchanged connected set does not cross the channel again", () async {
    connected("d1", "Laptop", PeerStatus.online);
    expect(work.synced, hasLength(1));

    // A status churn that leaves the connected set as it was — the error
    // state of another device's dial, say.
    connected("d1", "Laptop", PeerStatus.online);
    expect(work.synced, hasLength(1));
  });

  test("the notification's Disconnect closes every connected peer", () async {
    connected("d1", "Laptop", PeerStatus.online);

    work.stop(BackgroundJob.sync);
    await pumpEventQueue();

    expect(hub.peers.value["d1"]!.status, PeerStatus.offline);
    // And that is what releases the service: the emptied list.
    expect(work.synced.last, isNull);
  });

  group("the setting", () {
    test("survives save and load, and off writes nothing", () async {
      final config = tempConfig("sync_keep_alive_test_");
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
