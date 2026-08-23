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

  tearDown(() async {
    await hub.dispose();
    app.dispose();
  });

  Future<void> open(
    WidgetTester tester, {
    List<PairedDevice> paired = const [],
    String? relayUrl,
  }) async {
    final config = tempConfig();
    registry = FakeDeviceRegistry(paired);
    hub = await testSyncHub(
      config,
      devices: registry,
      settings: () => AppSettings(syncRelayUrl: relayUrl),
    );
    app = TestApp.create(hub: hub, devices: registry);
    await pumpSettings(tester, app, SettingsCategory.sync);
    await settleIo(tester);
  }

  testWidgets("this device is named by its own fingerprint", (tester) async {
    await open(tester);

    expect(find.text(hub.identity.fingerprint), findsOneWidget);
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
    });
  });
}
