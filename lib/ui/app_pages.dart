import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/pages/app_page.dart";
import "../app/settings/spec.dart";
import "../app/settings/controller.dart";
import "settings/form_dialog.dart" show editItem;
import "settings/schema_view.dart";
import "settings/setting_icons.dart";
import "widgets/document_view.dart";
import "widgets/web_view.dart";
import "widgets/dialogs.dart";
import "widgets/page_bar.dart";
import "widgets/section_header.dart";

/// Opens [page] onto the core's stack, which whichever frontend is on
/// screen draws: this one's [AppPagesFollower], or the native shell's.
void openAppPage(BuildContext context, AppPage page) =>
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appPagesProvider.notifier).open(page);

/// Keeps the Navigator in step with the core's stack: a page opened there
/// is pushed, one it closes is taken off, and one the user backs out of is
/// closed there. Mounted once, under the Navigator.
class AppPagesFollower extends ConsumerStatefulWidget {
  const AppPagesFollower({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppPagesFollower> createState() => _AppPagesFollowerState();
}

class _AppPagesFollowerState extends ConsumerState<AppPagesFollower> {
  final _routes = <String, Route<void>>{};

  @override
  void initState() {
    super.initState();
    ref.listenManual(appPagesProvider, (_, open) => _follow(open));
    _said = ref.read(appPagesProvider.notifier).said.listen((message) {
      if (mounted) notify(context, message);
    });
  }

  late final StreamSubscription<String> _said;

  @override
  void dispose() {
    _said.cancel();
    super.dispose();
  }

  void _follow(List<AppPage> open) {
    final navigator = Navigator.of(context);
    final addresses = {for (final p in open) p.address};
    for (final MapEntry(key: address, value: route)
        in _routes.entries.toList()) {
      if (addresses.contains(address)) continue;
      _routes.remove(address);
      if (route.isActive) navigator.removeRoute(route);
    }
    for (final page in open) {
      if (_routes.containsKey(page.address)) continue;
      final route = MaterialPageRoute<void>(builder: (_) => AppPageView(page));
      _routes[page.address] = route;
      navigator.push(route).then((_) {
        // Backed out of rather than closed by the core.
        if (_routes.remove(page.address) != null) {
          ref.read(appPagesProvider.notifier).close(page.address);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// An [AppPage] as a Flutter page: its sections as the settings draw
/// theirs, its actions in its bar, and what leaving asks asked before it
/// goes.
class AppPageView extends ConsumerWidget {
  const AppPageView(this.page, {super.key});

  final AppPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuilt when the page says it changed.
    ref.watch(appPagesProvider);
    final reader = WidgetReader(ref);
    final sections = page.sections(reader);
    final leaving = page.leaving(reader);
    final held = page.held(reader);
    return PopScope(
      canPop: leaving == null && !held,
      onPopInvokedWithResult: (popped, _) async {
        if (popped || held || leaving == null) return;
        final go = await confirm(
          context,
          title: leaving.title,
          message: leaving.message,
          confirmLabel: leaving.confirmLabel ?? "Discard",
          destructive: leaving.destructive,
        );
        if (go) ref.read(appPagesProvider.notifier).close(page.address);
      },
      child: Scaffold(
        appBar: PageBar(
          title: page.title(reader),
          subtitle: page.subtitle(reader),
          leading: held ? PageLeading.none : PageLeading.back,
          actions: _actions(context, page.toolbar(reader), sections),
        ),
        body: switch (sections) {
          [PageSection(fills: true, controllers: [final c])] => switch (c) {
            DocumentController() => DocumentView(c),
            WebController() => WebPageView(c),
            _ => SettingRow(c),
          },
          _ => ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final (i, section) in sections.indexed) ...[
                if (i > 0) const Divider(),
                if (section.title.isNotEmpty || section.detail != null)
                  SectionHeader(section.title, description: section.detail),
                for (final c in section.controllers)
                  if (c.visible) SettingRow(c),
                if (section.footnote case final footnote?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: mutedParagraph(
                      context,
                      footnote,
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ],
          ),
        },
      ),
    );
  }
}

/// The bar's buttons, an action with a glyph drawn as its icon: the page's
/// own — the first, unless it is secondary — at the end, where native
/// keeps it too.
List<PageAction> _actions(
  BuildContext context,
  List<ActionController> toolbar,
  List<PageSection> sections,
) {
  void Function()? press(ActionController action) {
    if (!action.enabled) return null;
    final adds = action.adds;
    if (adds == null) return () => runSettingAction(context, action);
    final list = sections
        .expand((s) => s.controllers)
        .whereType<CollectionController>()
        .where((c) => c.id == adds)
        .firstOrNull;
    if (list == null) return null;
    return () => list.typed(<V>(c) => editItem<V>(context, c));
  }

  PageAction drawn(ActionController action, {bool own = false}) {
    if (settingIcon(action.glyph) case final icon?) {
      return PageAction.icon(
        icon: icon,
        label: action.label,
        onPressed: press(action),
      );
    }
    return PageAction.text(
      label: action.label,
      prominent: own,
      onPressed: press(action),
    );
  }

  final shown = [
    for (final action in toolbar)
      if (action.visible) action,
  ];
  final own = shown.firstOrNull?.secondary == false ? shown.first : null;
  return [
    for (final action in shown)
      if (action != own) drawn(action),
    if (own != null) drawn(own, own: true),
  ];
}
