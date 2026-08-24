import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/sync/sync_hub.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/ui/settings/settings_page.dart";

import "../fakes.dart";
import "../harness.dart";

/// The Sync category, over a real [SyncHub] with no transport under it. What
/// it draws is the hub's own — the fingerprint, the peers, the pairing window
/// — so a faked hub would only ever prove the fake.
void main() {
  late TestApp app;
  late SyncHub hub;
  late FakeDeviceRegistry registry;
  late FakeRelaySignaling relay;

  tearDown(() async {
    await hub.dispose();
    app.dispose();
  });

  Future<void> open(
    WidgetTester tester, {
    List<PairedDevice> paired = const [],
    String? relayUrl,
    String? hostname,
    String? deviceName,
  }) async {
    registry = FakeDeviceRegistry(paired);
    relay = FakeRelaySignaling();
    hub = await testSyncHub(
      devices: registry,
      hostname: hostname,
      settings: () =>
          AppSettings(syncRelayUrl: relayUrl, deviceName: deviceName),
      relayDial: relay.dial,
    );
    // What `main` does once the container exists: it is what puts the
    // already-paired devices into `peers`, which is what the page draws.
    await hub.ensureReady();
    app = TestApp.create(hub: hub);
    await pumpSettings(tester, app, SettingsCategory.sync);
    await settleIo(tester);
  }

  testWidgets("this device is named by its own fingerprint", (tester) async {
    await open(tester);

    expect(find.text(hub.identity.fingerprint), findsOneWidget);
  });

  group("what the other device files this one under", () {
    testWidgets("the machine's own name, where it has one", (tester) async {
      await open(tester, hostname: "yiannis-laptop");

      expect(hub.deviceName, "yiannis-laptop");
      // The field is empty and the hint is what the default would be, rather
      // than a stand-in for it.
      expect(
          find.widgetWithText(TextFormField, "yiannis-laptop"), findsOneWidget);
    });

    testWidgets("a typed name wins over the hostname", (tester) async {
      await open(tester, hostname: "yiannis-laptop", deviceName: "Desk");

      expect(hub.deviceName, "Desk");
    });

    testWidgets("with no hostname it falls back to the key", (tester) async {
      await open(tester);

      expect(hub.deviceName, startsWith("Entoli "));
    });
  });

  testWidgets("with nothing paired it says how to start", (tester) async {
    await open(tester);

    expect(find.textContaining("No devices paired yet"), findsOneWidget);
  });

  group("a paired device", () {
    testWidgets("is listed, offline, with a way to dial it", (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      expect(find.text("Laptop"), findsOneWidget);
      expect(find.text("Connect"), findsOneWidget);
      expect(find.text("Disconnect"), findsNothing);
    });

    testWidgets("one that pairs while the page is open appears at once",
        (tester) async {
      await open(tester);
      expect(find.textContaining("No devices paired yet"), findsOneWidget);

      // What completing a pairing does: the registry gains the device and the
      // hub publishes it online. Read off the registry instead, the page went
      // on showing the list it had loaded when it was built.
      await registry.add(testPairedDevice("d1", name: "Laptop"));
      hub.peers.value = {
        "d1": PeerState(
            deviceId: "d1", name: "Laptop", status: PeerStatus.online),
      };
      await settleIo(tester);

      expect(find.text("Laptop"), findsOneWidget);
      expect(find.text("Disconnect"), findsOneWidget);
    });

    testWidgets("a dial that finds nothing says so rather than throwing",
        (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);
      await registry.setPairingSecret("d1", "test-psk");

      await scrollTo(tester, find.text("Connect"));
      await tester.tap(find.text("Connect"));
      await settleIo(tester);

      // No address and no relay: nowhere to look. The row keeps the reason
      // and the snack bar says which device it was.
      expect(find.textContaining("no route configured"), findsWidgets);
      expect(find.textContaining("could not reach Laptop"), findsOneWidget);
    });

    testWidgets("revoking asks first, and a refusal keeps the device",
        (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      await scrollTo(tester, find.text("Revoke"));
      await tester.tap(find.text("Revoke"));
      await settleIo(tester);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, "Cancel")));
      await settleIo(tester);

      expect(await registry.list(), hasLength(1));
      expect(find.text("Laptop"), findsOneWidget);
      expect(hub.peers.value, hasLength(1));
    });

    testWidgets("confirming takes it out of the registry", (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      await scrollTo(tester, find.text("Revoke"));
      await tester.tap(find.text("Revoke"));
      await settleIo(tester);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, "Revoke")));
      await settleIo(tester);

      expect(await registry.list(), isEmpty);
      // And out of the list the page draws, without leaving and coming back.
      await settleIo(tester);
      expect(find.text("Laptop"), findsNothing);
    });
  });

  group("opening a pairing window", () {
    testWidgets("with no route at all, it says why rather than doing nothing",
        (tester) async {
      await open(tester);

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      expect(find.textContaining("no relay URL is set"), findsOneWidget);
    });

    testWidgets("a relay URL is a route, and the window shows a code",
        (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      expect(hub.pairing.value?.qr, startsWith("entoli-pair:"));
      expect(find.text("Open pairing window"), findsNothing);
      // Holding the window is the "i" side, in the room the secret derives.
      expect(relay.dialled.single.$1, "wss://relay.example.com");
      expect(relay.dialled.single.$3, "i");
    });
  });
}
