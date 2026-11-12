import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/settings/hand_off.dart";
import "package:agent_chat/app/settings/spec.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/app_theme.dart";
import "package:agent_chat/domain/sync/devices.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:agent_chat/ui/shell/shell_settings.dart";
import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";
import "../../harness.dart";
import "native_settings.g.dart";

/// The Swift's settings, as far as these tests need them: what it was told
/// to open, and every device sent, over the real channels and codec.
class _FakeNativeSettings implements TestNativeSettings {
  final opened = <String>[];
  final devices = <(String, PairedDeviceData?, String?)>[];

  @override
  void settings(SettingsSnapshot snapshot) {}

  @override
  void show(SettingsPageKey? page) {}

  @override
  void openDevice(String id) => opened.add(id);

  @override
  void device(String id, PairedDeviceData? device, String? readError) =>
      devices.add((id, device, readError));

  /// The app's pages as each stack was sent.
  final stacks = <List<SettingsPageData>>[];

  @override
  void appPages(List<SettingsPageData> stack) => stacks.add(stack);
}

/// A page with one toggle, which leaving asks about once it is flipped.
class _Page extends AppPage {
  bool on = false;

  @override
  String get address => "test";

  @override
  String title(SettingReader reader) => "Test";

  @override
  SettingConfirm? leaving(SettingReader reader) => on
      ? const SettingConfirm(
          title: "Discard?",
          message: "It was flipped.",
          confirmLabel: "Discard",
        )
      : null;

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("s", "", [
      ToggleController(
        part("flip", "Flip", hint: UiHint.toggle),
        value: on,
        effective: on,
        onSet: (value) async {
          on = value ?? false;
          changed();
          return null;
        },
      ),
    ]),
  ];
}

void main() {
  late TestApp app;
  // Held, so the pages are built once a test rather than on every read.
  late ProviderSubscription<NativeSettingsPages> pages;
  late FakeDeviceRegistry devices;
  late SyncIdentity peer;

  // Sync's rows read the hub, which a default test app has none of.
  setUp(() async {
    peer = await SyncIdentity.load(FakeSecretStore());
    devices = FakeDeviceRegistry([
      PairedDevice(
        id: "peer",
        name: "Laptop",
        publicKey: peer.publicKeyB64,
        addedAt: DateTime.utc(2026, 1, 2),
        addresses: const ["192.168.1.4:7420"],
      ),
    ]);
    app = TestApp.create(hub: await testSyncHub(devices: devices));
    app.container
        .read(nativeShownPagesProvider.notifier)
        .show(SettingsPageId.values.toSet());
    pages = app.container.listen(nativeSettingsProvider, (_, _) {});
  });
  tearDown(() {
    pages.close();
    app.dispose();
  });

  List<SettingRowData> rowsOf(SettingsPageKey key) => [
    for (final page in pages.read().snapshot.pages)
      if (page!.key == key)
        for (final section in page.sections) ...section!.rows.nonNulls,
  ];

  testWidgets("every page the platform offers is sent, Welcome left out", (
    tester,
  ) async {
    final keys = [for (final page in pages.read().snapshot.pages) page!.key];
    expect(keys, contains(SettingsPageKey.general));
    expect(keys, contains(SettingsPageKey.syncRelay));
    expect(keys, isNot(contains(SettingsPageKey.welcome)));
  });

  testWidgets("a page not drawn is sent with no rows", (tester) async {
    app.container.read(nativeShownPagesProvider.notifier).show({
      SettingsPageId.general,
    });
    expect(rowsOf(SettingsPageKey.general), isNotEmpty);
    expect(rowsOf(SettingsPageKey.llms), isEmpty);
  });

  testWidgets("a row says what its controller holds", (tester) async {
    final theme = rowsOf(
      SettingsPageKey.general,
    ).firstWhere((r) => r.id == "appTheme");
    expect(theme.kind, SettingKind.choice);
    expect(theme.hint, SettingHint.segmented);
    expect(theme.options.map((o) => o!.label), [
      for (final theme in AppTheme.values) theme.label,
    ]);
    expect(theme.picked, AppTheme.values.indexOf(AppTheme.system));
  });

  testWidgets("a group's rows follow it, naming it their parent", (
    tester,
  ) async {
    final rows = rowsOf(SettingsPageKey.llms);
    final at = rows.indexWhere((r) => r.id == "autoCompact");
    expect(rows[at].kind, SettingKind.group);
    expect(rows[at + 1].id, "autoCompact.on");
    expect(rows[at + 1].parent, "autoCompact");
  });

  testWidgets("an intent naming a row sets what its controller sets", (
    tester,
  ) async {
    final bridge = SettingsBridge(app.container);
    addTearDown(bridge.close);

    bridge.pick("appTheme", AppTheme.values.indexOf(AppTheme.dark));
    await settleIo(tester);

    expect(AppSettings.load(app.config).appTheme, AppTheme.dark);
    expect(
      rowsOf(
        SettingsPageKey.general,
      ).firstWhere((r) => r.id == "appTheme").picked,
      AppTheme.values.indexOf(AppTheme.dark),
    );
  });

  testWidgets("a switch's intent sets it", (tester) async {
    final bridge = SettingsBridge(app.container);
    addTearDown(bridge.close);

    bridge.toggle("showCommandChips", true);
    await settleIo(tester);

    expect(AppSettings.load(app.config).showCommandChips, isTrue);
  });

  testWidgets("a sub-page says the page that opens it, a listed one none", (
    tester,
  ) async {
    final from = {
      for (final page in pages.read().snapshot.pages)
        page!.key: page.openedFrom,
    };
    expect(from[SettingsPageKey.syncRelay], SettingsPageKey.sync);
    expect(from[SettingsPageKey.onDeviceLlm], SettingsPageKey.onDevice);
    expect(from[SettingsPageKey.general], isNull);
  });

  group("a paired device's page", () {
    late _FakeNativeSettings native;
    late SettingsBridge bridge;

    setUp(() {
      native = _FakeNativeSettings();
      TestNativeSettings.setUp(native);
      addTearDown(() => TestNativeSettings.setUp(null));
      bridge = SettingsBridge(app.container);
      addTearDown(bridge.close);
    });

    testWidgets("opens on the client once the shell binds it", (tester) async {
      final handOff = app.container.read(settingsHandOffProvider);
      bridge.bindDevicePage(handOff);
      await handOff.pairedDevice!("peer");
      await settleIo(tester);
      expect(native.opened, ["peer"]);
    });

    testWidgets("sends the record while it is shown", (tester) async {
      bridge.deviceShown("peer");
      await settleIo(tester);

      final (id, device, readError) = native.devices.last;
      expect(id, "peer");
      expect(readError, isNull);
      expect(device!.name, "Laptop");
      expect(device.status, DeviceStatus.offline);
      expect(device.addresses, ["192.168.1.4:7420"]);
      expect(device.fingerprint, peer.fingerprint);
      expect(device.addedMs, DateTime.utc(2026, 1, 2).millisecondsSinceEpoch);
    });

    testWidgets("sends none for a device no longer paired", (tester) async {
      bridge.deviceShown("gone");
      await settleIo(tester);

      final (id, device, readError) = native.devices.last;
      expect(id, "gone");
      expect(device, isNull);
      expect(readError, isNull);
    });

    testWidgets("renames the record by its intent", (tester) async {
      final notice = await io(
        tester,
        () => bridge.deviceAction("peer", DeviceOp.rename, "Desk"),
      );
      expect(notice, isNull);
      expect((await io(tester, () => devices.byId("peer")))!.name, "Desk");
    });
  });

  group("the app's pages", () {
    late _FakeNativeSettings native;
    late SettingsBridge bridge;

    setUp(() {
      native = _FakeNativeSettings();
      TestNativeSettings.setUp(native);
      addTearDown(() => TestNativeSettings.setUp(null));
      bridge = SettingsBridge(app.container);
      addTearDown(bridge.close);
    });

    testWidgets("a page opened is sent as the stack, its rows its own", (
      tester,
    ) async {
      final page = _Page();
      app.container.read(appPagesProvider.notifier).open(page);
      await settleIo(tester);

      final sent = native.stacks.last.single;
      expect(sent.key, SettingsPageKey.app);
      expect(sent.address, "test");
      final row = sent.sections.single!.rows.single!;
      expect(row.id, "page:test/flip");

      bridge.toggle(row.id, true);
      await settleIo(tester);
      expect(page.on, isTrue);
      expect(native.stacks.last.single.guarded, isTrue);
    });

    testWidgets("leaving asks what the page asks, and closing takes it", (
      tester,
    ) async {
      final page = _Page()..on = true;
      app.container.read(appPagesProvider.notifier).open(page);
      await settleIo(tester);

      final ask = await io(tester, () => bridge.leavePage("test"));
      expect(ask?.confirmLabel, "Discard");
      expect(app.container.read(appPagesProvider), [page]);

      bridge.closePage("test");
      await settleIo(tester);
      expect(app.container.read(appPagesProvider), isEmpty);
      expect(native.stacks.last, isEmpty);
    });
  });
}
