import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/settings.dart";
import "../widgets/side_panel_frame.dart";
import "settings_category.dart";
import "schema_view.dart";
import "../../app/pages/welcome.dart" show WelcomeAppPage;
import "../app_pages.dart";
import "../widgets/page_bar.dart";

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialCategory, this.focus = false});

  final SettingsCategory? initialCategory;

  /// Pushed for one category — the welcome tour's setup rows, the Byte Repair
  /// bar — rather than arrived at through the settings list. That category is
  /// the whole page on a wide window too, with nothing behind it: back leaves
  /// settings rather than a list it skipped, and the panel is not drawn
  /// beside what it was not used to pick.
  final bool focus;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// General until something else is picked, so a wide window always has a
  /// category beside the list and a narrow one has it highlighted there.
  late SettingsCategory _category =
      widget.initialCategory ?? SettingsCategory.general;

  /// Whether the category is in front of the list in a narrow window. Kept
  /// whatever the width, so a window narrowed after a pick lands on what the
  /// user was reading rather than back on the list. A named category opens
  /// in front; otherwise the list is what settings shows first.
  late bool _categoryShown = widget.initialCategory != null;

  /// Back from a category to the list, by the bar's button or the back key.
  void _showList() => setState(() => _categoryShown = false);

  bool _holds(SettingsCategory category) =>
      ref.watch(settingsPageHeldProvider(category.page));

  @override
  Widget build(BuildContext context) {
    // A category this platform does not offer is not opened, whoever names it.
    if (widget.initialCategory case final initial?
        when widget.focus && initial.offered(ref)) {
      return PopScope(
        canPop: !_holds(initial),
        child: Scaffold(
          appBar: PageBar(title: initial.label),
          body: _categoryBody(initial),
        ),
      );
    }
    final category = _category.offered(ref)
        ? _category
        : SettingsCategory.general;
    // Held, every way out is shut: back, the bar's button and another pick.
    final held = _holds(category);
    return PopScope(
      canPop: !held,
      child: SidePanelFrame(
        narrow: SidePanelNarrow.page,
        contentShown: _categoryShown,
        onHideContent: held ? null : _showList,
        // The list is settings' own structure, so it is never hidden: nothing
        // takes the bar's leading slot from its back button. In front of the
        // list the button is drawn whatever is under the route, since it goes
        // back to the list rather than out of settings.
        bar: (mode) => mode == SidePanelMode.contentPage
            ? PageBar(title: category.label, onBack: held ? null : _showList)
            : PageBar(title: "Settings"),
        panel: _Categories(
          selected: category,
          onSelect: (picked) {
            if (held) return;
            setState(() {
              _category = picked;
              _categoryShown = true;
            });
          },
        ),
        child: _categoryBody(category, key: ValueKey(category)),
      ),
    );
  }
}

/// What a category draws in either layout: its schema page. Welcome is the
/// way to the tour, a page of the app's own.
Widget _categoryBody(SettingsCategory category, {Key? key}) =>
    switch (category) {
      SettingsCategory.welcome => Builder(
        key: key,
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => openAppPage(context, WelcomeAppPage(replay: true)),
            child: const Text("Take the Welcome Tour"),
          ),
        ),
      ),
      _ => ListView(key: key, children: [SchemaSections(category.page)]),
    };

/// The categories as a list: beside the page where there is room for one, and
/// the page itself where there is not. Material, not Scaffold, since the
/// frame owns that.
class _Categories extends ConsumerWidget {
  const _Categories({required this.selected, required this.onSelect});

  final SettingsCategory selected;
  final ValueChanged<SettingsCategory> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    child: SafeArea(
      child: ListView(
        children: [
          for (final category in SettingsCategory.values)
            if (category.offered(ref)) ...[
              if (category.dividerAbove) const Divider(),
              ListTile(
                selected: category == selected,
                leading: Icon(category.icon),
                title: Text(category.label),
                onTap: () => onSelect(category),
              ),
            ],
        ],
      ),
    ),
  );
}
