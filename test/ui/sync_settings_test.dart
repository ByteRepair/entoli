import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:qr_flutter/qr_flutter.dart";

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
    // The app-level settings the page's rows read, the same relay URL and
    // name the hub dials and announces.
    unawaited(app.seedSettings(
        AppSettings(syncRelayUrl: relayUrl, deviceName: deviceName)));
    await pumpSettings(tester, app, SettingsCategory.sync);
    await settleIo(tester);
  }

  testWidgets("the fingerprint is nowhere on the page", (tester) async {
    await open(tester);

    // The user has no use for it: nothing on screen pairs, mirrors or
    // verifies with it, and no peer fingerprint is shown to compare against.
    expect(find.text(hub.identity.fingerprint), findsNothing);
    expect(find.text("Device fingerprint"), findsNothing);
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
      // Four hex, and none of the grouping's spaces: the name carries the
      // fingerprint's first group, and nothing else of it.
      expect(hub.deviceName,
          matches(RegExp(r'^Entoli [0-9A-F]{4}$')));
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
      // The button pushed the window page, so it is gone from the list behind.
      expect(find.text("Open pairing window"), findsNothing);
      // Holding the window is the "i" side, in the room the secret derives.
      expect(relay.dialled.single.$1, "wss://relay.example.com");
      expect(relay.dialled.single.$3, "i");
    });

    testWidgets("the window page shows a QR for the code", (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      // The window page renders the QR and the selectable code, not the inline
      // box the list used to draw.
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining("entoli-pair:"), findsOneWidget);
    });

    testWidgets("going back from the window page cancels it", (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);
      expect(hub.pairing.value, isNotNull);

      await tester.pageBack();
      await settleIo(tester);

      expect(hub.pairing.value, isNull);
    });
  });

  group("relay and TURN settings", () {
    testWidgets("are screens of their own, behind their rows", (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com:9999");

      // The rows carry their state and open their screens; no field is on
      // this page for either.
      await scrollTo(tester, find.text("Internet relay"));
      expect(find.text("Relay URL"), findsNothing);
      expect(find.text("TURN URL"), findsNothing);

      await tester.tap(find.text("Internet relay"));
      await settleIo(tester);

      expect(find.text("Relay URL"), findsOneWidget);
      expect(find.text("wss://relay.example.com:9999"), findsOneWidget);

      await tester.pageBack();
      await settleIo(tester);

      await tester.tap(find.text("TURN server"));
      await settleIo(tester);

      expect(find.text("TURN URL"), findsOneWidget);
      expect(find.text("TURN username"), findsOneWidget);
      expect(find.text("TURN password"), findsOneWidget);

      await tester.pageBack();
      await settleIo(tester);

      // Back on the same page, rows and controls intact.
      expect(find.text("Internet relay"), findsOneWidget);
      expect(find.text("Open pairing window"), findsOneWidget);
    });

    testWidgets("their rows show what they hold", (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("TURN server"));
      expect(find.text("wss://relay.example.com"), findsOneWidget);
    });
  });

  group("a finished pairing", () {
    testWidgets("this page keeps its controls", (tester) async {
      await open(tester);
      // What completing a pairing leaves behind here now: nothing — the
      // paired screen was wherever the pairing ran, and this page's controls
      // were never swapped out for a status.
      hub.pairing.value =
          PairingActivity(stage: PairingStage.done, peerName: "Laptop");
      await settleIo(tester);

      expect(find.text("Open pairing window"), findsOneWidget);
      expect(find.text("Pair"), findsOneWidget);
      expect(find.textContaining("has been paired"), findsNothing);
    });
  });

  group("the pairing window's own page", () {
    testWidgets("it ends on the paired screen, and Done leaves the controls",
        (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      hub.pairing.value =
          PairingActivity(stage: PairingStage.done, peerName: "Phone");
      await settleIo(tester);

      expect(find.text("Device Phone has been paired."), findsOneWidget);

      await tester.tap(find.text("Done"));
      await settleIo(tester);

      expect(hub.pairing.value, isNull);
      expect(find.text("Open pairing window"), findsOneWidget);
    });

    testWidgets("pairing another from it opens a fresh window on it",
        (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);
      hub.pairing.value =
          PairingActivity(stage: PairingStage.done, peerName: "Phone");
      await settleIo(tester);

      await tester.tap(find.text("Pair another device"));
      await settleIo(tester);

      // The second window: a new QR, a new room.
      expect(find.byType(QrImageView), findsOneWidget);
      expect(hub.pairing.value?.stage, PairingStage.connecting);
      expect(relay.dialled.length, 2);

      // Leaving the second window cancels it and its page.
      await tester.pageBack();
      await settleIo(tester);

      expect(hub.pairing.value, isNull);
      expect(find.text("Open pairing window"), findsOneWidget);
    });

    testWidgets("its codes-matched view names the other device", (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      hub.pairing.value = PairingActivity(
          stage: PairingStage.confirming, sas: "AAAA", peerName: "Phone");
      await settleIo(tester);

      expect(find.textContaining("Phone"), findsOneWidget);
      expect(find.textContaining("AAAA"), findsOneWidget);
    });

    testWidgets("a pairing that cannot finish fails on that screen",
        (tester) async {
      await open(tester, relayUrl: "wss://relay.example.com");

      await scrollTo(tester, find.text("Open pairing window"));
      await tester.tap(find.text("Open pairing window"));
      await settleIo(tester);

      hub.pairing.value = PairingActivity(
          stage: PairingStage.failed, error: "the relay refused us");
      await settleIo(tester);

      expect(find.text("Failed: the relay refused us"), findsOneWidget);
    });
  });

  group("pairing from a pasted code", () {
    testWidgets("a code that is not one says so, on its own screen",
        (tester) async {
      await open(tester);

      await scrollTo(tester, find.text("Pair"));
      await tester.enterText(find.byType(TextFormField).last, "not a code");
      await tester.tap(find.text("Pair"));
      await settleIo(tester);

      expect(find.textContaining("not an Entoli pairing code"), findsOneWidget);
      // Back where the pair started, controls never gone.
      expect(find.text("Or paste a pairing code"), findsOneWidget);
    });

    // A paired screen for a pasted code is the same `_PairingStageView` the
    // window page's test above proves, over an activity this file has no way
    // of starting on the wire: `pairWith` on a real code reaches `RtcLink`,
    // which needs a WebRTC engine the VM has none of. Between the two, one
    // honest screen each way and the stages shared, the joiner's flows are
    // covered to the point where only a live channel would add to it.
  });

  group("clicking a paired device's row", () {
    testWidgets("opens the device's own page", (tester) async {
      final device = testPairedDevice("d1", name: "Laptop");
      await open(tester, paired: [device]);

      await scrollTo(tester, find.text("Laptop"));
      await tester.tap(find.text("Laptop"));
      await settleIo(tester);

      // The record, the rename, and both fingerprints — nothing of the sync
      // page's rows behind it. The header is a category, not the name again.
      expect(find.text("Paired device"), findsOneWidget);
      expect(find.text("Laptop"), findsOneWidget);
      expect(find.text("Last connected"), findsOneWidget);
      expect(find.text("Rename"), findsOneWidget);
      expect(find.text("This device"), findsOneWidget);
      expect(find.text(hub.identity.fingerprint), findsOneWidget);
      // The stored key's, from the record itself.
      expect(find.text(device.fingerprint!), findsOneWidget);
      expect(find.text("Open pairing window"), findsNothing);
    });

    testWidgets("renaming lands in the registry and on the row",
        (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      await scrollTo(tester, find.text("Laptop"));
      await tester.tap(find.text("Laptop"));
      await settleIo(tester);

      await tester.tap(find.text("Rename"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField), "Desk");
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, "Rename")));
      await settleIo(tester);

      expect(await registry.byId("d1"), isNotNull);
      expect((await registry.byId("d1"))!.name, "Desk");
      // The page's name followed (once — the header stays a category), and
      // the row behind kept it.
      expect(find.text("Desk"), findsOneWidget);
      await tester.pageBack();
      await settleIo(tester);
      expect(find.text("Desk"), findsOneWidget);
    });

    testWidgets("cancelling the rename leaves the record", (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      await scrollTo(tester, find.text("Laptop"));
      await tester.tap(find.text("Laptop"));
      await settleIo(tester);
      await tester.tap(find.text("Rename"));
      await settleIo(tester);

      await tester.enterText(find.byType(TextField), "Desk");
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, "Cancel")));
      await settleIo(tester);

      expect((await registry.byId("d1"))!.name, "Laptop");
      expect(find.text("Laptop"), findsOneWidget);
    });
  });

  group("the paired device page's own actions", () {
    testWidgets("connect is there, and a failed dial says so on the page",
        (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);
      await registry.setPairingSecret("d1", "test-psk");

      await scrollTo(tester, find.text("Laptop"));
      await tester.tap(find.text("Laptop"));
      await settleIo(tester);

      await tester.tap(find.text("Connect"));
      await settleIo(tester);

      // The page kept the device, and said why — the snack bar on it and the
      // reason on its own status row, the way the list row's dial does.
      expect(find.textContaining("could not reach Laptop"), findsOneWidget);
      expect(find.textContaining("no route configured"), findsWidgets);
    });

    testWidgets("revoke is there, asks first, and confirming pops",
        (tester) async {
      await open(tester, paired: [testPairedDevice("d1", name: "Laptop")]);

      await scrollTo(tester, find.text("Laptop"));
      await tester.tap(find.text("Laptop"));
      await settleIo(tester);

      await scrollTo(tester, find.text("Revoke"));
      await tester.tap(find.text("Revoke"));
      await settleIo(tester);

      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, "Revoke")));
      await settleIo(tester);

      // Off the page: the record is gone and so is the row behind, without
      // the page having to be closed and reopened.
      expect(await registry.list(), isEmpty);
      expect(find.text("Laptop"), findsNothing);
      expect(find.textContaining("No devices paired yet"), findsOneWidget);
    });
  });

  group("keeping connected off screen", () {
    // Android's row only — the one platform whose process freezes with the
    // screen. The override is undone in the body: flutter_test refuses
    // letting it leak past the test.
    testWidgets("the switch is Android's, and writes the setting", (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await open(tester);

        await scrollTo(tester, find.text("Keep connected off screen"));
        await tester.tap(find.text("Keep connected off screen"));
        await settleIo(tester);

        expect(AppSettings.load(app.config).syncKeepAlive, isTrue);

        await tester.tap(find.text("Keep connected off screen"));
        await settleIo(tester);

        expect(AppSettings.load(app.config).syncKeepAlive, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets("nothing of it is drawn anywhere else", (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await open(tester);

        expect(find.text("Keep connected off screen"), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
