import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../domain/temp_chat_ttl.dart";
import "../settings/controller.dart";
import "../settings/scope.dart";
import "../settings/settings.dart";
import "../settings/spec.dart";

/// A page of the app's that is not a setting — a chat's settings, the plan,
/// the workspace, the marketplace — said as data: its title, its sections of
/// the settings' controllers, what its bar offers and what leaving it asks.
/// A frontend draws it the way it draws a settings page, and every change
/// goes through the controllers, so the page's logic is here and nowhere
/// else. Opened onto [AppPages].
abstract class AppPage {
  /// Which page this is among the open ones, and the prefix of every part's
  /// id: what an intent names it by.
  String get address;

  String title(SettingReader reader);

  String? subtitle(SettingReader reader) => null;

  List<PageSection> sections(SettingReader reader);

  /// The bar's buttons, the first the page's own (Save, Done, Install).
  List<ActionController> toolbar(SettingReader reader) => const [];

  /// What going back asks, where leaving would lose something; null goes.
  SettingConfirm? leaving(SettingReader reader) => null;

  /// [leaving]'s question for a page of unsaved edits.
  static const discardChanges = SettingConfirm(
    title: "Discard changes?",
    message: "What you changed here is not saved.",
    confirmLabel: "Discard",
    destructive: true,
  );

  /// Left only by its own actions: no back, no cancel, no swipe. What a
  /// first launch shows before the app.
  bool held(SettingReader reader) => false;

  /// The app, as the page reads it outside a pass — a load, a save — set
  /// as the page opens.
  late final SettingReader app;

  /// Put on the stack, [app] set: where a page starts what it loads.
  void opened() {}

  late final Ref _ref;

  /// The container the page's stack is in, for a model of the app's that
  /// takes one.
  ProviderContainer get container => _ref.container;

  /// The stack the page is on: what it opens another page onto, and leaves.
  late final AppPages pages;

  /// Hears [provider] until the returned subscription is closed: what a page
  /// waits on outside a pass, a download it started.
  ProviderSubscription<T> listen<T>(
    ProviderListenable<T> provider,
    void Function(T? previous, T next) listener,
  ) => _ref.listen<T>(provider, listener);

  /// Gone from the stack.
  void closed() {}

  /// Set by the stack while the page is open.
  void Function()? onChanged;

  /// What the page draws has changed somewhere its reader does not watch:
  /// its own state, a load landing.
  void changed() => onChanged?.call();

  /// A part of the page under an id of its own, for a controller to be built
  /// with. The page builds it; nothing files it in the schema.
  SettingSpec part(
    String id,
    String title, {
    UiHint hint = UiHint.row,
    String? description,
    SettingGlyph? glyph,
  }) => SettingSpec(
    id: "$_parts$address/$id",
    path: (page: null, section: ""),
    weight: 0,
    title: title,
    hint: hint,
    description: description,
    glyph: glyph,
    build: _unfiled,
  );

  /// A section that says [text] and nothing else: a page still loading, or
  /// what it is about.
  PageSection notice(
    String id,
    String text, {
    NoticeTone tone = NoticeTone.plain,
  }) => PageSection(id, "", [
    NoticeController(part(id, ""), tone: tone, lines: [NoticeLine(text)]),
  ]);

  /// A row that opens [page] over this one.
  SettingController opener(
    String id,
    String title,
    AppPage Function() page, {
    String? description,
    String label = "",
    SettingGlyph? glyph,
  }) => ActionController(
    part(id, title, hint: UiHint.open, description: description, glyph: glyph),
    label: label,
    run: () async {
      pages.open(page());
      return null;
    },
  );

  /// Where a mirrored [what] lives, and that it cannot be changed while
  /// [device] is offline.
  PageSection deviceNotice(
    String what,
    String device, {
    required bool online,
  }) => notice(
    "device",
    online
        ? "This $what lives on $device."
        : "$device is offline. These settings can be changed once it is "
              "back.",
    tone: online ? NoticeTone.plain : NoticeTone.warning,
  );

  /// How long a temporary chat lives, unset standing for [inherited].
  ChoiceController<TempChatTtl> tempTtlChoice(
    String title, {
    required TempChatTtl? value,
    required TempChatTtl inherited,
    required Future<void> Function(TempChatTtl? ttl) onSet,
  }) => ChoiceController<TempChatTtl>(
    part("ttl", title, hint: UiHint.dropdown),
    options: [
      for (final ttl in TempChatTtl.values) SettingOption(ttl, ttl.label),
    ],
    value: value,
    unsettable: true,
    inherited: inherited,
    onSet: (ttl) async {
      await onSet(ttl);
      return null;
    },
  );

  /// The settings' own [id], built at [scope] on this page under an id of
  /// the page's: the same rules and words as on the settings page, whatever
  /// level that spec is filed at there.
  SettingController shared(
    SettingReader reader,
    SettingsScope scope,
    String id,
  ) {
    final spec = reader.read(settingsSchemaProvider).settings[id]!;
    return spec.build(
      SettingContext(reader, scope, spec.withId("$_parts$address/$id")),
    );
  }

  /// [page] of the settings at [at], as this page's sections, each under
  /// an id of this page's.
  List<PageSection> settingsPage(
    SettingReader reader,
    SettingsPageId page,
    ScopeAddress at,
  ) {
    final schema = reader.watch(settingsSchemaProvider);
    final scopes = <ScopeAddress, SettingsScope>{};
    return [
      for (final (section, specs) in schema.page(page))
        if (section.shown?.call(reader) ?? true)
          PageSection(section.id, section.title, [
            for (final spec in specs)
              shared(
                reader,
                scopes.putIfAbsent(
                  spec.at ?? at,
                  () => scopeAt(reader, spec.at ?? at),
                ),
                spec.id,
              ),
          ], detail: section.describe?.call(reader) ?? section.description),
    ];
  }

  /// What every part's id starts with, apart from the settings' own.
  static const _parts = "page:";

  /// Whether [id] names a part of an app page rather than a setting.
  static bool owns(String id) => id.startsWith(_parts);

  static SettingController _unfiled(SettingContext _) =>
      throw StateError("a page's part is built by the page");
}

/// A titled run of a page's controllers.
class PageSection {
  const PageSection(this.id, this.title, this.controllers, {this.detail})
    : fills = false;

  /// [controller] as the whole of its page rather than a row of a form: a
  /// file, a web page. The page's only section.
  PageSection.whole(this.id, SettingController controller)
    : title = "",
      detail = null,
      controllers = [controller],
      fills = true;

  final String id;
  final String title;
  final String? detail;
  final List<SettingController> controllers;
  final bool fills;
}

/// The pages open, the first at the bottom: each one opened over the one
/// before it. The core's, so where a page goes is decided once; a frontend
/// draws the stack and says when the user leaves one.
class AppPages extends Notifier<List<AppPage>> {
  @override
  List<AppPage> build() {
    ref.onDispose(_said.close);
    return const [];
  }

  final _said = StreamController<String>.broadcast();

  /// What a page that closed itself had to say — "Installed x." — for the
  /// frontend to say in passing, the page that would have said it gone.
  Stream<String> get said => _said.stream;

  AppPage? find(String address) =>
      state.where((p) => p.address == address).firstOrNull;

  /// Opens [page] over the others; one already open at its address comes to
  /// the top, the pages over it closing.
  void open(AppPage page) {
    final at = state.indexWhere((p) => p.address == page.address);
    if (at >= 0) {
      state = _closeFrom(at + 1);
      return;
    }
    page
      ..onChanged = _notify
      .._ref = ref
      ..pages = this
      ..app = RefReader(ref);
    state = [...state, page];
    page.opened();
  }

  /// A page's load still running says nothing to a stack that is gone.
  void _notify() {
    if (ref.mounted) ref.notifyListeners();
  }

  /// Closes [address] and every page over it.
  void close(String address) {
    final at = state.indexWhere((p) => p.address == address);
    if (at >= 0) state = _closeFrom(at);
  }

  /// Closes [page], from inside it: Save, Done; [saying] what it did.
  void leave(AppPage page, {String? saying}) {
    close(page.address);
    if (saying != null) _said.add(saying);
  }

  void closeAll() {
    if (state.isNotEmpty) state = _closeFrom(0);
  }

  List<AppPage> _closeFrom(int at) {
    for (final page in state.sublist(at).reversed) {
      page
        ..onChanged = null
        ..closed();
    }
    return state.sublist(0, at);
  }
}

final appPagesProvider = NotifierProvider<AppPages, List<AppPage>>(
  AppPages.new,
);
