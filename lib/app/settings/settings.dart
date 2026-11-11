import "package:flutter_riverpod/flutter_riverpod.dart";

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

/// The setting [id] at [address], built through [reader].
SettingController buildSetting(
  SettingReader reader,
  SettingsSchema schema,
  String id,
  ScopeAddress address,
) {
  final spec = schema.settings[id];
  if (spec == null) throw ArgumentError.value(id, "id", "no such setting");
  return spec.build(SettingContext(reader, scopeAt(reader, address), spec));
}

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
  final scope = scopeAt(reader, address);
  return [
    for (final (section, specs) in schema.page(page))
      if (section.shown?.call(reader) ?? true)
        if ([
              for (final spec in specs)
                spec.build(SettingContext(reader, scope, spec)),
            ].where((c) => c.visible).toList()
            case final shown when shown.isNotEmpty)
          SectionView(
            section,
            section.describe?.call(reader) ?? section.description,
            shown,
          ),
  ];
}

/// [page] at [address], for a frontend that is sent it rather than building
/// it: rebuilt whenever what it reads changes.
final settingsPageProvider =
    Provider.family<List<SectionView>, (SettingsPageId, ScopeAddress)>(
      (ref, key) => buildPage(
        RefReader(ref),
        ref.watch(settingsSchemaProvider),
        key.$1,
        key.$2,
      ),
    );
