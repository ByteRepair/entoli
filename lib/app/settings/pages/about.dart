import "../../../core/brand.dart";
import "../../../providers.dart";
import "../../app_items.dart";
import "../controller.dart";
import "../spec.dart";

final _repository = Uri.parse("https://github.com/ByteRepair/entoli");

/// Who made it: on the About page, and under the licences.
const madeBy = "Made by Yiannis Charalambous";

final aboutSections = [
  const SectionSpec(
    page: SettingsPageId.about,
    id: "about",
    title: "About",
    weight: 0,
  ),
  // On every platform: a phone or tablet can have a keyboard attached, and
  // then they work there too.
  const SectionSpec(
    page: SettingsPageId.shortcuts,
    id: "shortcuts",
    title: "Keyboard shortcuts",
    weight: 0,
  ),
];

final aboutSettings = [
  // What this build is, who made it, and where the source is. The libraries
  // are the frontend's own licence page rather than a list kept here.
  SettingSpec(
    id: "about",
    path: (page: SettingsPageId.about, section: "about"),
    weight: 0,
    title: "About",
    hint: UiHint.info,
    build: (c) {
      final version = c.ref.watch(appVersionProvider);
      return InfoController(
        c.spec,
        rows: [
          InfoRow(
            appBrand,
            subtitle: version == null ? null : "Version $version",
            glyph: SettingGlyph.appMark,
          ),
          const InfoRow(madeBy, glyph: SettingGlyph.person),
          InfoRow(
            "Source on GitHub",
            subtitle: "$_repository",
            glyph: SettingGlyph.code,
            link: _repository,
          ),
          const InfoRow(
            "Privacy policy",
            glyph: SettingGlyph.privacy,
            opens: InfoPage.privacyPolicy,
          ),
          const InfoRow(
            "Open source libraries",
            subtitle: "Everything Entoli is built on, and its licence.",
            glyph: SettingGlyph.licence,
            opens: InfoPage.licences,
          ),
        ],
      );
    },
  ),
  SettingSpec(
    id: "shortcuts",
    path: (page: SettingsPageId.shortcuts, section: "shortcuts"),
    weight: 0,
    title: "Keyboard shortcuts",
    hint: UiHint.info,
    build: (c) => InfoController(
      c.spec,
      rows: [
        for (final item in appItems)
          if (item.key case final key?) InfoRow(item.title, keys: key),
      ],
    ),
  ),
];
