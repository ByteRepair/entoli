import "dart:async";

import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/settings/spec.dart";

import "../../harness.dart";

/// An [AppPage] opened on [app]'s stack and read as a frontend would: its
/// sections and its bar through the container, and what it does waited on
/// through the stack's own change notices rather than through time.
class PageDriver<P extends AppPage> {
  PageDriver(this.app, this.page) {
    _heard = app.container.listen(appPagesProvider, (_, _) => _changed());
    app.container.read(appPagesProvider.notifier).open(page);
  }

  final TestApp app;
  final P page;

  late final _heard;
  Completer<void>? _next;

  void _changed() {
    _next?.complete();
    _next = null;
  }

  ContainerReader get reader => ContainerReader(app.container);

  /// Whether the page is still on the stack.
  bool get open => app.container.read(appPagesProvider).contains(page);

  List<PageSection> get sections => page.sections(reader);

  /// Every controller drawn, a group's children among them.
  List<SettingController> get controllers => [
    for (final section in sections)
      for (final c in section.controllers) ..._flat(c),
  ];

  static Iterable<SettingController> _flat(SettingController c) sync* {
    yield c;
    if (c case GroupController(:final children)) {
      for (final child in children) {
        yield* _flat(child);
      }
    }
  }

  String _id(String part) => "page:${page.address}/$part";

  /// The controller built for [part], or null where the page draws none.
  T? find<T extends SettingController>(String part) =>
      controllers.whereType<T>().where((c) => c.id == _id(part)).firstOrNull;

  T at<T extends SettingController>(String part) {
    final found = find<T>(part);
    if (found == null) {
      throw StateError(
        "no $T $part on ${page.address}: ${controllers.map((c) => c.id)}",
      );
    }
    return found;
  }

  /// The bar's action [part].
  ActionController tool(String part) =>
      page.toolbar(reader).firstWhere((a) => a.id == _id(part));

  ActionController? findTool(String part) =>
      page.toolbar(reader).where((a) => a.id == _id(part)).firstOrNull;

  /// Waits for [holds], checked again each time the page or the stack says
  /// something changed: a load landing, a save closing it.
  Future<void> until(bool Function() holds) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!holds()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException("the page never came to it");
      }
      final next = _next ??= Completer<void>();
      // A change made by real I/O lands on its own; a microtask chain may
      // finish without a notice, so look again after a round of the loop.
      await Future.any([next.future, Future<void>.delayed(Duration.zero)]);
    }
  }

  void close() {
    _heard.close();
    if (open) app.container.read(appPagesProvider.notifier).close(page.address);
  }
}
