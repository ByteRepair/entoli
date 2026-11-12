import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../providers.dart";
import "catalog.dart";
import "controller.dart";
import "schema.dart";
import "scope.dart";
import "spec.dart";

/// The schema every frontend builds its settings from: the page
/// declarations under `pages/`.
final settingsSchemaProvider = Provider<SettingsSchema>(
  (ref) => entoliSettings,
);

/// [page] at [address] as it stands, built through [reader]: the sections
/// with something in them, in order. A frontend that builds its widgets from
/// this in place passes its widget's ref, so nothing derived sits between the
/// settings and what is drawn.
List<SectionView> buildPage(
  SettingReader reader,
  SettingsSchema schema,
  SettingsPageId page,
  ScopeAddress address,
) {
  final scopes = <ScopeAddress, SettingsScope>{};
  return [
    for (final (section, specs) in schema.page(page))
      ?_build(reader, section, specs, address, scopes),
  ];
}

/// [page]'s [section] alone, where it has something in it: [only] keeps to
/// those settings where it names any.
SectionView? buildSection(
  SettingReader reader,
  SettingsSchema schema,
  SettingsPageId page,
  String section,
  ScopeAddress address, {
  Set<String>? only,
}) {
  for (final (spec, specs) in schema.page(page)) {
    if (spec.id != section) continue;
    return _build(
      reader,
      spec,
      [
        for (final s in specs)
          if (only?.contains(s.id) ?? true) s,
      ],
      address,
      {},
    );
  }
  return null;
}

SectionView? _build(
  SettingReader reader,
  SectionSpec section,
  List<SettingSpec> specs,
  ScopeAddress address,
  Map<ScopeAddress, SettingsScope> scopes,
) {
  if (!(section.shown?.call(reader) ?? true)) return null;
  final shown = [
    for (final spec in specs)
      spec.build(
        SettingContext(
          reader,
          scopes.putIfAbsent(
            spec.at ?? address,
            () => scopeAt(reader, spec.at ?? address),
          ),
          spec,
        ),
      ),
  ].where((c) => c.visible).toList();
  if (shown.isEmpty && !section.keepEmpty) return null;
  return SectionView(
    section,
    section.describe?.call(reader) ?? section.description,
    shown,
  );
}

/// Whether this platform can do anything [page] sets. One it cannot is
/// neither listed nor opened, so its page never has to say so. On-device
/// holds the model server's downloads and the voice models', so a build with
/// neither has no page to offer.
bool pageOffered(SettingReader ref, SettingsPageId page) => switch (page) {
  SettingsPageId.agentBrowser => ref.watch(agentBrowserProvider).available,
  SettingsPageId.triggers => ref.watch(reminderAlarmsProvider).available,
  SettingsPageId.onDevice =>
    ref.watch(localEngineProvider).available ||
        ref.watch(voiceProvider).hasModelCatalog,
  _ => page.listed,
};
