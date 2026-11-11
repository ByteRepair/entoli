import "controller.dart";
import "spec.dart";

/// Every section and setting, from each page's own declarations.
class SettingsSchema {
  SettingsSchema({
    required List<SectionSpec> sections,
    required List<SettingSpec> settings,
  }) : sections = {for (final s in sections) "${s.page.name}/${s.id}": s},
       settings = {for (final s in settings) s.id: s} {
    assert(this.sections.length == sections.length, "a section id is taken");
    assert(this.settings.length == settings.length, "a setting id is taken");
    for (final s in settings) {
      assert(
        this.sections.containsKey("${s.path.page.name}/${s.path.section}"),
        "${s.id} is filed under no section",
      );
    }
  }

  final Map<String, SectionSpec> sections;
  final Map<String, SettingSpec> settings;

  /// [page]'s sections in order, each with its settings in order.
  List<(SectionSpec, List<SettingSpec>)> page(SettingsPageId page) {
    final found = [
      for (final section in sections.values)
        if (section.page == page)
          (
            section,
            [
              for (final s in settings.values)
                if (s.path.page == page && s.path.section == section.id) s,
            ]..sort((a, b) => a.weight.compareTo(b.weight)),
          ),
    ];
    return found..sort((a, b) => a.$1.weight.compareTo(b.$1.weight));
  }
}

/// A section as it stands: its words, and the controllers to draw in it.
class SectionView {
  const SectionView(this.spec, this.description, this.settings);

  final SectionSpec spec;
  final String? description;
  final List<SettingController> settings;
}
