import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/app_theme.dart";
import "package:agent_chat/ui/shell/shell_settings.dart";
import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

void main() {
  late TestApp app;

  // Sync's rows read the hub, which a default test app has none of.
  setUp(() async => app = TestApp.create(hub: await testSyncHub()));
  tearDown(() => app.dispose());

  List<SettingRowData> rowsOf(SettingsPageKey key) => [
    for (final page
        in app.container.read(nativeSettingsProvider).snapshot.pages)
      if (page!.key == key)
        for (final section in page.sections) ...section!.rows.nonNulls,
  ];

  testWidgets("every page the platform offers is sent, Welcome left out", (
    tester,
  ) async {
    final keys = [
      for (final page
          in app.container.read(nativeSettingsProvider).snapshot.pages)
        page!.key,
    ];
    expect(keys, contains(SettingsPageKey.general));
    expect(keys, contains(SettingsPageKey.syncRelay));
    expect(keys, isNot(contains(SettingsPageKey.welcome)));
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

  testWidgets("nothing is built until the settings are shown", (tester) async {
    final bridge = SettingsBridge(app.container);
    addTearDown(bridge.close);
    expect(app.container.exists(nativeSettingsProvider), isFalse);

    bridge.shown(true);
    expect(app.container.exists(nativeSettingsProvider), isTrue);
    await settleIo(tester);
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
}
