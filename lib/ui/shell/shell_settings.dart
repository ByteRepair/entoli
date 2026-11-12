import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/pages/app_page.dart";
import "../../app/settings/controller.dart";
import "../../app/bot_avatar/library.dart";
import "../../app/bot_avatar/stage.dart";
import "../../app/model_facts.dart";
import "../../app/model_picker.dart";
import "../../app/settings/forms/model.dart";
import "../../app/settings/hand_off.dart";
import "../../app/settings/scope.dart";
import "../../app/settings/settings.dart";
import "../../app/settings/spec.dart";
import "../../core/formatting.dart";
import "../../core/log.dart";
import "../../data/builtin/llm/hosted_models.dart" show ModelHost;
import "../../data/privacy_policy_data.dart";
import "../../domain/agent_face.dart";
import "../../domain/bot_avatar/import.dart";
import "../../domain/bot_avatar/pose.dart";
import "../../domain/bot_avatar/spec.dart";
import "../../domain/model_registry.dart" show ModelCatalog;
import "../../providers.dart";
import "../../app/prompts/skill_files.dart";
import "shell_device.dart";

/// Every page the native settings offer, as rows, and the controller each
/// row was sent from, by its id: what an intent naming a row acts on.
typedef NativeSettingsPages = ({
  SettingsSnapshot snapshot,
  Map<String, SettingController> controllers,
});

/// The pages the native settings draw now; the rest are sent as titles.
final nativeShownPagesProvider =
    NotifierProvider<NativeShownPages, Set<SettingsPageId>>(
      NativeShownPages.new,
    );

class NativeShownPages extends Notifier<Set<SettingsPageId>> {
  @override
  Set<SettingsPageId> build() => const {};

  void show(Set<SettingsPageId> pages) {
    if (!setEquals(pages, state)) state = pages;
  }
}

/// The pages this platform offers, the shown ones built through the
/// provider's ref and rebuilt whenever anything one reads changes. A page
/// not of settings, the tour, stays the app's own.
final nativeSettingsProvider = Provider.autoDispose<NativeSettingsPages>((ref) {
  final reader = RefReader(ref);
  final shown = ref.watch(nativeShownPagesProvider);
  final schema = ref.watch(settingsSchemaProvider);
  final controllers = <String, SettingController>{};
  final encode = _Encoder(ref, controllers);
  final pages = [
    for (final page in SettingsPageId.values)
      if (page.settings && (!page.listed || pageOffered(reader, page)))
        SettingsPageData(
          key: SettingsPageKey.values.byName(page.name),
          title: page.title,
          groupStart: page.groupStart,
          openedFrom: switch (page.openedFrom) {
            final from? => SettingsPageKey.values.byName(from.name),
            null => null,
          },
          sections: [
            if (shown.contains(page))
              for (final section in buildPage(
                reader,
                schema,
                page,
                const AppAddress(),
              ))
                encode.section(
                  PageSection(
                    section.spec.id,
                    section.spec.title,
                    section.settings,
                    detail: section.description,
                  ),
                ),
          ],
        ),
  ];
  return (snapshot: SettingsSnapshot(pages: pages), controllers: controllers);
});

/// The app's pages open, each as a settings page drawn over the window, and
/// their controllers by id.
final nativeAppPagesProvider = Provider.autoDispose<NativeSettingsPages>((ref) {
  final reader = RefReader(ref);
  final open = ref.watch(appPagesProvider);
  final controllers = <String, SettingController>{};
  final encode = _Encoder(ref, controllers);
  final pages = [
    for (final page in open)
      SettingsPageData(
        key: SettingsPageKey.app,
        address: page.address,
        title: page.title(reader),
        subtitle: page.subtitle(reader),
        guarded: page.leaving(reader) != null,
        sections: [for (final s in page.sections(reader)) encode.section(s)],
        toolbar: [
          for (final action in page.toolbar(reader))
            if (action.visible) ...encode.rows(action),
        ],
      ),
  ];
  return (snapshot: SettingsSnapshot(pages: pages), controllers: controllers);
});

/// Sections as rows, reading what a row draws — a model pick's label, an
/// agent's face — through the provider's ref, and keeping each controller
/// sent under its id.
class _Encoder {
  _Encoder(this.ref, this.controllers);

  final Ref ref;
  final Map<String, SettingController> controllers;

  late final _providers = ref.watch(appSettingsProvider).llmProviders;
  late final _models = ref.watch(sortedModelsProvider);
  late final _serving = ref.watch(modelProvidersProvider);
  late final _stage = ref.watch(botStageProvider);

  SettingsSectionData section(PageSection section) => SettingsSectionData(
    id: section.id,
    title: section.title,
    detail: section.detail,
    rows: [for (final c in section.controllers) ...rows(c)],
  );

  List<SettingRowData> rows(SettingController c) =>
      _rows(c, controllers, label, face);

  _ModelField label(ModelPickController c) {
    final listed = _models.value ?? const [];
    final error = modelFieldError(
      choice: c.choice,
      role: c.role,
      loaded: _models.hasValue,
      listed: listed,
      serving: _serving,
    );
    return (
      label: error != null
          ? missingModelLabel
          : modelFieldLabel(
              choice: c.choice,
              role: c.role,
              nullLabel: c.nullLabel,
              defaultOf: c.defaultOf,
              providers: _providers,
              listed: listed,
              serving: _serving,
            ),
      error: error,
    );
  }

  /// A Bot Avatar is drawn live by the client from its rig; a photo is sent.
  _Face face(({String? project, String name}) agent) =>
      switch (ref.watch(agentPictureProvider(agent)).value) {
        AgentPhoto(:final bytes) => (photo: bytes, bot: null, colour: null),
        AgentBot(:final spec) => (
          photo: null,
          bot: _stage.keyOf(spec.definition),
          colour: spec.colour,
        ),
        null => (photo: null, bot: null, colour: null),
      };
}

/// What a model pick's field reads as, and why it is wrong.
typedef _ModelField = ({String label, String? error});

/// An agent's face: a photo's bytes, or a Bot Avatar as the stage's key and
/// its colour; all null for none, or not read yet.
typedef _Face = ({Uint8List? photo, String? bot, int? colour});

/// [c] as the rows that carry it: its own, then a group's children and an
/// accessory, each naming it their parent.
List<SettingRowData> _rows(
  SettingController c,
  Map<String, SettingController> controllers,
  _ModelField Function(ModelPickController c) label,
  _Face Function(({String? project, String name}) agent) face, {
  String? parent,
  bool accessory = false,
}) {
  controllers[c.id] = c;
  return [
    _row(c, label, face, parent: parent, accessory: accessory),
    if (c case GroupController(:final children))
      for (final child in children)
        if (child.visible)
          ..._rows(child, controllers, label, face, parent: c.id),
    if (c.accessory case final action?)
      ..._rows(action, controllers, label, face, parent: c.id, accessory: true),
  ];
}

SettingIcon? _icon(SettingGlyph? glyph) =>
    glyph == null ? null : SettingIcon.values.byName(glyph.name);

SettingTone _tone(NoticeTone tone) => SettingTone.values.byName(tone.name);

SettingConfirmData? _confirm(SettingConfirm? ask) => ask == null
    ? null
    : SettingConfirmData(
        title: ask.title,
        message: ask.message,
        confirmLabel: ask.confirmLabel,
        destructive: ask.destructive,
        brief: ask.brief,
        cancelled: ask.cancelled,
      );

SettingNoticeData? _notice(SettingNotice? notice) => notice == null
    ? null
    : SettingNoticeData(
        title: notice.title,
        message: notice.message,
        copy: notice.copy,
      );

SettingOptionData _option(SettingOption option) => SettingOptionData(
  label: option.label,
  detail: option.detail,
  enabled: option.enabled,
  argb: switch (option.look) {
    SwatchLook(:final argb) => argb,
    _ => null,
  },
  argb2: switch (option.look) {
    SwatchLook(:final second) => second,
    _ => null,
  },
  radius: switch (option.look) {
    CornerLook(:final radius) => radius,
    _ => null,
  },
);

SettingRowData _row(
  SettingController c,
  _ModelField Function(ModelPickController c) label,
  _Face Function(({String? project, String name}) agent) face, {
  String? parent,
  bool accessory = false,
}) {
  final row = SettingRowData(
    id: c.id,
    kind: SettingKind.toggle,
    hint: SettingHint.values.byName(c.hint.name),
    title: c.title,
    detail: c.description,
    footnote: c.footnote,
    enabled: c.enabled,
    icon: _icon(c.glyph),
    parent: parent,
    accessory: accessory,
  );
  switch (c) {
    case ToggleController():
      row
        ..on = c.value
        ..effective = c.effective
        ..unsettable = c.unsettable;
    case ChoiceController():
      final options = c.options;
      final index = options.indexWhere((o) => o.value == c.value);
      row
        ..kind = SettingKind.choice
        ..options = [for (final o in options) _option(o)]
        ..picked = index < 0 ? null : index
        ..unsettable = c.unsettable
        ..inheritedLabel = c.inheritedLabel
        ..noneLabel = c.noneLabel
        ..error = c.error;
    case SlotsController():
      final all = [for (final g in c.groups) ...g.options];
      row
        ..kind = SettingKind.slots
        ..options = [for (final slot in c.slots) _option(slot)]
        ..groups = [
          for (final g in c.groups)
            SettingGroupData(
              label: g.label,
              options: [for (final o in g.options) _option(o)],
            ),
        ]
        ..slotPicks = [
          for (final slot in c.slots)
            all.indexWhere((o) => o.value == slot.value),
        ];
    case RangeController():
      row
        ..kind = SettingKind.range
        ..value = c.value
        ..inherited = c.inherited
        ..stops = c.stops ?? const []
        ..min = c.min
        ..max = c.max
        ..unsettable = c.unsettable;
    case KeyValuesController():
      row
        ..kind = SettingKind.keyValues
        ..entries = c.entries
        ..masked = c.masked;
    case ActionController():
      row
        ..kind = SettingKind.action
        ..label = c.label
        ..destructive = c.destructive
        ..secondary = c.secondary;
    case GroupController():
      row
        ..kind = SettingKind.group
        ..busy = c.busy;
    case NumberController():
      row
        ..kind = SettingKind.number
        ..value = c.value
        ..inherited = c.fallback
        ..min = c.min
        ..max = c.max
        ..unit = c.unit
        ..prompt = c.prompt;
    case ModelPickController():
      final field = label(c);
      row
        ..kind = SettingKind.modelPick
        ..modelLabel = field.label
        ..error = field.error
        ..noneLabel = c.nullLabel;
    case TextController():
      row
        ..kind = SettingKind.text
        ..text = c.value
        ..emptyLabel = c.emptyLabel
        ..prompt = c.prompt
        ..secret = c.secret
        ..lines = c.lines
        ..submitLabel = c.submitLabel
        ..clearLabel = c.clearLabel;
    case DocumentController():
      row
        ..kind = SettingKind.document
        ..text = c.text
        ..fileName = c.name
        ..markdown = c.markdown
        ..editing = c.editing;
    case NoticeController():
      row
        ..kind = SettingKind.notice
        ..notice = [
          for (final line in c.lines)
            SettingLineData(text: line.text, url: line.url?.toString()),
        ]
        ..tone = _tone(c.tone);
    case CollectionController():
      _Face? faceOf(CollectionItem item) =>
          item.face == null ? null : face(item.face!);
      row
        ..kind = SettingKind.collection
        ..items = [
          for (final item in c.rows)
            if (faceOf(item) case final face)
              SettingItemData(
                title: item.title,
                subtitle: item.subtitle,
                error: item.error,
                icon: _icon(item.glyph),
                tone: _tone(item.tone),
                on: item.on,
                opens: _textPage(item.opens),
                tap: item.tap,
                badge: item.badge,
                meters: [
                  for (final meter in item.meters)
                    SettingMeterData(
                      text: meter.text,
                      fraction: meter.fraction,
                    ),
                ],
                editable: item.editable,
                image: face?.photo,
                bot: face?.bot,
                botColour: face?.colour,
                actions: [
                  for (final action in c.actionsOf(item))
                    SettingItemActionData(
                      kind: SettingActionKind.values.byName(action.kind.name),
                      id: action.id,
                      label: action.label,
                      enabled: action.enabled,
                      destructive: action.destructive,
                      confirm: _confirm(action.confirm),
                      handsOff: action.handsOff,
                    ),
                ],
              ),
        ]
        ..addLabel = c.addLabel
        ..removeLabel = c.removeLabel
        ..removable = c.removable
        ..editable = c.editable
        ..emptyItems = c.emptyLabel;
    case CatalogController():
      row
        ..kind = SettingKind.catalog
        ..catalog = [
          for (final item in c.items)
            SettingCatalogData(
              id: item.id,
              title: item.title,
              summary: item.summary,
              note: item.note,
              badge: item.badge,
              tags: [
                if (item.facts case final f?)
                  for (final (_, text) in modelFactTags(f)) text,
              ],
              failure: item.failure,
              received: item.progress?.received,
              total: item.progress?.total,
              unpacking: item.progress?.unpacking ?? false,
              installed: item.installed,
              downloadable: item.downloadable,
              updatable: item.updatable,
              deleteConfirm: _confirm(item.deleteConfirm),
            ),
        ]
        ..addLabel = c.addLabel;
    case InfoController():
      row
        ..kind = SettingKind.info
        ..info = [
          for (final info in c.rows)
            SettingInfoData(
              title: info.title,
              subtitle: info.subtitle,
              icon: _icon(info.glyph),
              keyChar: info.keys?.char,
              keyShift: info.keys?.shift ?? false,
              keyAlt: info.keys?.alt ?? false,
              link: info.link?.toString(),
              opens: _textPage(info.opens),
            ),
        ];
    case SubpageController():
      row
        ..kind = SettingKind.subpage
        ..page = SettingsPageKey.values.byName(c.page.name)
        ..summary = c.summary;
    case PairingController():
      final activity = c.activity;
      row
        ..kind = SettingKind.pairing
        ..canScan = c.canScan
        ..pairing = activity == null
            ? null
            : SettingPairingData(
                stage: SettingPairingStage.values.byName(activity.stage.name),
                qr: activity.qr,
                code: activity.code,
                sas: activity.sas,
                peerName: activity.peerName,
                error: activity.error,
              );
    case SetupController():
      final tools = c.tools;
      row
        ..kind = SettingKind.setup
        ..blocked = c.blocked
        ..setupNotice = c.notice
        ..prerequisiteWhy = c.prerequisite?.why
        ..prerequisiteCommand = c.prerequisite?.command
        ..tools = tools == null
            ? null
            : [
                for (final MapEntry(key: name, value: version) in tools.entries)
                  SettingToolData(name: name, version: version),
              ]
        ..running = c.running
        ..error = c.error
        ..deleteConfirm = _confirm(c.deleteConfirm)
        ..setUpLabel = c.setUpLabel
        ..importLabel = c.importLabel
        ..deleteLabel = c.deleteLabel;
  }
  return row;
}

/// [options] as sent; a multi's [picked] each with its flip.
List<FormOptionData> _formOptions(
  List<FormOption> options, {
  FormMulti? multi,
  Set<String> picked = const {},
}) => [
  for (final option in options)
    FormOptionData(
      picked: picked.contains(option.answer),
      flipped: multi == null
          ? null
          : FormMulti.encode(
              multi.toggled(
                picked,
                option.answer,
                !picked.contains(option.answer),
              ),
            ),
      answer: option.answer,
      label: option.label,
      help: option.help,
      group: option.group,
      icon: _icon(option.glyph),
      tags: [
        for (final tag in option.tags)
          FormTagData(text: tag.text, tone: _tone(tag.tone)),
      ],
      kind: option.kind,
    ),
];

TextPageData? _textPage(TextPage? page) => switch (page) {
  null => null,
  PolicyPage() => TextPageData(kind: TextPageKind.privacyPolicy),
  InlinePage(:final text) => TextPageData(
    kind: TextPageKind.inline,
    text: text,
  ),
  LicencesPage() => TextPageData(kind: TextPageKind.licences),
  SkillPage(:final name, :final project) => TextPageData(
    kind: TextPageKind.skill,
    name: name,
    project: project,
  ),
};

/// [answers] as the client sends them, every key a string.
Map<String, String> _answersOf(Map<String?, String?> answers) => {
  for (final MapEntry(:key, :value) in answers.entries) ?key: value ?? "",
};

/// What a submit threw, as the form says it.
FormSaveData _refusal(Object e) => switch (e) {
  FormRefusal() => FormSaveData(
    message: e.message,
    field: e.field,
    anyway: e.anyway,
    anywayLabel: e.anywayLabel,
    yes: formYes,
  ),
  _ => FormSaveData(message: "$e"),
};

/// The native settings' end of the app: sends every page as it changes, and
/// runs what the client says the user did against the controller the row
/// was sent from.
class SettingsBridge implements SettingsIntents {
  SettingsBridge(this._container) {
    SettingsIntents.setUp(this);
    _opened = _container.listen<List<AppPage>>(
      appPagesProvider,
      (_, open) => _follow(open),
      fireImmediately: true,
    );
  }

  final ProviderContainer _container;
  late final _reader = ContainerReader(_container);
  final _native = NativeSettings();
  late final _device = ShellDevicePage(_container, _native);

  /// Binds [handOff]'s paired device to the client's own page of it.
  void bindDevicePage(SettingsHandOff handOff) => handOff
    ..pairedDevice = _native.openDevice
    ..pairedDeviceInSettings = true;

  @override
  void deviceShown(String? id) => _device.show(id);

  @override
  Future<SettingNoticeData?> deviceAction(
    String id,
    DeviceOp op,
    String? name,
  ) => _device.act(id, op, name);

  /// The pages as they change, while the settings are on screen.
  ProviderSubscription<NativeSettingsPages>? _sending;

  late final ProviderSubscription<List<AppPage>> _opened;

  /// The app's pages as they change, while any is open.
  ProviderSubscription<NativeSettingsPages>? _sendingPages;

  void _follow(List<AppPage> open) {
    if (open.isEmpty) {
      _sendingPages?.close();
      _sendingPages = null;
      _sendPages(const []);
      return;
    }
    _sendingPages ??= _container.listen<NativeSettingsPages>(
      nativeAppPagesProvider,
      (_, pages) => _sendPages(pages.snapshot.pages.nonNulls.toList()),
      onError: (e, _) => logFailure("pages", "building a page", e),
      fireImmediately: true,
    );
  }

  void _sendPages(List<SettingsPageData> stack) => unawaited(
    _native.appPages(stack).catchError((Object e) {
      logFailure("pages", "sending the pages", e);
    }),
  );

  AppPages get _pages => _container.read(appPagesProvider.notifier);

  @override
  Future<SettingConfirmData?> leavePage(String address) async {
    final page = _pages.find(address);
    if (page == null) return null;
    final ask = page.leaving(_reader);
    if (ask == null) _pages.close(address);
    return _confirm(ask);
  }

  @override
  void closePage(String address) => _pages.close(address);

  @override
  void shown(bool on, List<SettingsPageKey?> pages) {
    _container.read(nativeShownPagesProvider.notifier).show({
      for (final key in pages.nonNulls)
        if (key != SettingsPageKey.app) SettingsPageId.values.byName(key.name),
    });
    if (!on) {
      _sending?.close();
      _sending = null;
      return;
    }
    _sending ??= _container.listen<NativeSettingsPages>(
      nativeSettingsProvider,
      (_, pages) => _send(pages),
      // A page that cannot be built says why rather than taking the shell
      // down with it.
      onError: (e, _) => logFailure("settings", "building the pages", e),
      fireImmediately: true,
    );
  }

  /// An action's controller from when it was asked, run on its agreement:
  /// what it opened while asking is that instance's.
  final _asked = <String, ActionController>{};

  bool _failed = false;

  void _send(NativeSettingsPages pages) {
    unawaited(
      _native.settings(pages.snapshot).catchError((Object e) {
        // A client that is not listening — a test, a launch that never
        // drew the shell — is said once, not on every change.
        if (!_failed) logFailure("settings", "sending the pages", e);
        _failed = true;
      }),
    );
  }

  /// Opens the native settings, at [page] where it names one.
  Future<void> show(SettingsPageId? page) => _native.show(
    page == null ? null : SettingsPageKey.values.byName(page.name),
  );

  void close() {
    _opened.close();
    _sendingPages?.close();
    shown(false, const []);
    _device.close();
    SettingsIntents.setUp(null);
  }

  T? _at<T extends SettingController>(String id) {
    final c = _container
        .read(
          id.startsWith("page:")
              ? nativeAppPagesProvider
              : nativeSettingsProvider,
        )
        .controllers[id];
    return c is T ? c : null;
  }

  @override
  void toggle(String id, bool? on) => _at<ToggleController>(id)?.set(on);

  @override
  void pick(String id, int? option) {
    final c = _at<ChoiceController>(id);
    if (c == null) return;
    c.typed(<V>(c) {
      final value = option == null ? null : c.options[option].value;
      return c.set(value);
    });
  }

  @override
  void pickSlot(String id, int slot, int option) {
    final c = _at<SlotsController>(id);
    if (c == null) return;
    c.typed(<V>(c) {
      final all = [for (final g in c.groups) ...g.options];
      return c.set(slot, all[option].value);
    });
  }

  @override
  void setNumber(String id, int? value) {
    final c = _container.read(nativeSettingsProvider).controllers[id];
    switch (c) {
      case RangeController():
        c.set(value);
      case NumberController():
        c.set(value ?? c.fallback);
      default:
    }
  }

  @override
  void setText(String id, String text) => switch (_at<SettingController>(id)) {
    final TextController c => c.set(text),
    final DocumentController c => c.edit(text),
    _ => null,
  };

  @override
  void putEntry(String id, String name, String value, String? replacing) =>
      _at<KeyValuesController>(id)?.put(name, value, replacing: replacing);

  @override
  void removeEntry(String id, String name) =>
      _at<KeyValuesController>(id)?.remove(name);

  @override
  void setModel(String id, String? providerId, String? modelId) =>
      _at<ModelPickController>(
        id,
      )?.set((providerId: providerId, modelId: modelId));

  @override
  Future<SettingConfirmData?> ask(String id) async {
    final c = _at<ActionController>(id);
    if (c == null) return null;
    _asked[id] = c;
    return _confirm(await c.confirm());
  }

  @override
  Future<SettingNoticeData?> run(String id) async {
    final c = _asked.remove(id) ?? _at<ActionController>(id);
    return _notice(await c?.run());
  }

  @override
  Future<SettingNoticeData?> itemAction(
    String id,
    int index,
    String action,
  ) async => _notice(await _at<CollectionController>(id)?.act(index, action));

  @override
  void removeItem(String id, int index) =>
      _at<CollectionController>(id)?.remove(index);

  @override
  void itemImage(String id, int index, Uint8List png) =>
      _at<CollectionController>(id)?.setImage(index, png);

  @override
  void itemBotAvatar(String id, int index, String key, int colour) {
    final definition = _stage.definition(key);
    if (definition == null) return;
    unawaited(
      _at<CollectionController>(id)?.setBotAvatar(
        index,
        BotAvatarSpec(definition: definition, colour: colour),
      ),
    );
  }

  @override
  Future<SettingFormData> form(
    String id,
    int? index,
    Map<String?, String?>? answers,
  ) async {
    final form = _formOf(id, index);
    if (form == null) {
      return SettingFormData(title: "", answers: const {}, parts: const []);
    }
    return _formData(form, answers);
  }

  /// [form] as it stands for [answers], its first where they are null.
  static SettingFormData _formData(
    SettingForm<Object?> form,
    Map<String?, String?>? answers,
  ) {
    final now = answers == null ? {...form.initial} : _answersOf(answers);
    final problem = form.problem(now);
    return SettingFormData(
      title: form.title,
      answers: now,
      problem: problem,
      savable: problem == null,
      parts: [
        for (final part in form.fields(now))
          switch (part) {
            FormQuestion(:final text) => FormPartData(
              kind: FormPartKind.question,
              label: text,
            ),
            FormText() => FormPartData(
              kind: FormPartKind.text,
              id: part.id,
              label: part.label,
              hint: part.hint,
              helper: part.helper,
              error: part.error,
              focused: part.focused,
              lines: part.lines,
              enabled: part.enabled,
              secret: part.secret,
              file: part.file,
            ),
            FormPrompt() => FormPartData(
              kind: FormPartKind.prompt,
              id: part.id,
              label: part.label,
              hint: part.hint,
              lines: 8,
              enabled: part.enabled,
            ),
            FormChoice() => FormPartData(
              kind: FormPartKind.choice,
              id: part.id,
              label: part.label,
              options: _formOptions(part.options),
              enabled: part.enabled,
              segmented: part.segmented,
              cards: part.cards,
            ),
            FormLink() => FormPartData(
              kind: FormPartKind.link,
              label: part.label,
              url: part.url.toString(),
              prominent: part.prominent,
            ),
            FormFold() => FormPartData(
              kind: FormPartKind.fold,
              id: part.id,
              label: part.label,
              on: part.open(now),
              flipped: part.open(now) ? "" : formYes,
            ),
            FormConsent() => FormPartData(
              kind: FormPartKind.consent,
              id: part.id,
              label: part.title,
              message: part.message,
              accept: part.accept,
              linkLabel: part.link?.$1,
              url: part.link?.$2.toString(),
              on: part.given(now),
              flipped: formYes,
            ),
            FormEntries() => FormPartData(
              kind: FormPartKind.entries,
              id: part.id,
              label: part.label,
              hint: FormEntries.format,
              helper: part.helper,
              enabled: part.enabled,
            ),
            FormSignIn(:final config) => FormPartData(
              kind: FormPartKind.signIn,
              label: config.displayName,
            ),
            FormDate() => FormPartData(
              kind: FormPartKind.date,
              id: part.id,
              label: part.label,
              enabled: part.enabled,
            ),
            FormDuration() => FormPartData(
              kind: FormPartKind.duration,
              id: part.id,
              label: part.label,
              helper: part.helper,
              enabled: part.enabled,
            ),
            FormMulti() => _multi(part, FormMulti.decode(now[part.id])),
            FormNote(:final text) => FormPartData(
              kind: FormPartKind.note,
              label: text,
            ),
          },
      ],
    );
  }

  static FormPartData _multi(FormMulti part, Set<String> picked) =>
      FormPartData(
        kind: FormPartKind.multi,
        id: part.id,
        label: part.label,
        error: part.error,
        options: _formOptions(part.options, multi: part, picked: picked),
        enabled: part.enabled,
        all: part.all,
        on: part.allOn(picked),
        flipped: FormMulti.encode(part.withAll(picked, !part.allOn(picked))),
      );

  /// The form a collection's item at [index], or a new one, is edited
  /// through.
  SettingForm<Object?>? _formOf(String id, int? index) =>
      _at<CollectionController>(
        id,
      )?.typed(<V>(c) => c.form?.call(index == null ? null : c.items[index]));

  @override
  Future<FormSaveData?> submitForm(
    String id,
    int? index,
    Map<String?, String?> answers,
  ) async {
    try {
      await _at<CollectionController>(
        id,
      )?.submit(_answersOf(answers), index: index);
      return null;
    } catch (e) {
      return _refusal(e);
    }
  }

  @override
  Future<void> formSignIn(
    String id,
    int? index,
    Map<String?, String?> answers,
    bool again,
  ) async {
    final form = _formOf(id, index);
    final now = _answersOf(answers);
    final signIn = form?.fields(now).whereType<FormSignIn>().firstOrNull;
    final hook = _container.read(settingsHandOffProvider).signIn;
    if (signIn == null || hook == null) return;
    await hook(signIn.config, again: again);
  }

  @override
  void formDismissed(String id, int? index, Map<String?, String?> answers) =>
      unawaited(_formOf(id, index)?.dismissed(_answersOf(answers)));

  @override
  void catalog(String id, String item, CatalogOp op) {
    final c = _at<CatalogController>(id);
    if (c == null) return;
    switch (op) {
      case CatalogOp.download:
        c.download(item);
      case CatalogOp.cancel:
        c.cancel(item);
      case CatalogOp.delete:
        c.delete(item);
      case CatalogOp.add:
        c.add();
    }
  }

  @override
  void pairing(String id, PairingOp op) {
    final c = _at<PairingController>(id);
    if (c == null) return;
    switch (op) {
      case PairingOp.openWindow:
        unawaited(c.flow.openWindow());
      case PairingOp.closeWindow:
        c.flow.closeWindow();
      case PairingOp.match:
        c.flow.confirm(true);
      case PairingOp.mismatch:
        c.flow.confirm(false);
      case PairingOp.scan:
        unawaited(c.scan());
      case PairingOp.cancel:
        c.flow.cancel();
    }
  }

  @override
  Future<String?> pairWith(String id, String code) async {
    try {
      await _at<PairingController>(id)?.flow.join(code);
      return null;
    } catch (e) {
      return "$e";
    }
  }

  @override
  Future<String> createInvite(String id) async =>
      await _at<PairingController>(id)?.flow.createInvite() ?? "";

  @override
  void setup(String id, SetupOp op) {
    final c = _at<SetupController>(id);
    if (c == null) return;
    switch (op) {
      case SetupOp.setUp:
        unawaited(c.setUp());
      case SetupOp.importTool:
        unawaited(c.import());
      case SetupOp.delete:
        unawaited(c.delete());
    }
  }

  List<CatalogEntry> _catalogOf(ModelPickController c) => catalogEntries(
    ModelCatalog.notifier.value,
    _container.read(modelProvidersProvider),
    _container.read(sortedModelsProvider).value ?? const [],
    role: c.role,
    host: ModelHost.resolving(
      cutsUtterances: _container.read(voiceProvider).hasModelCatalog,
    ),
  );

  @override
  Future<ModelPickerData> models(String id) async {
    final c = _at<ModelPickController>(id);
    if (c == null) {
      return ModelPickerData(
        title: "Choose a model",
        quick: const [],
        models: const [],
        favourites: const [],
        providers: const [],
      );
    }
    final providers = pickerProviders(_reader, c.role);
    final entries = _catalogOf(c);
    final favourites = _container.read(appSettingsProvider).favouriteModels;
    final starred = favourites.toSet();
    final view = pickerView(
      entries: entries,
      providers: providers,
      favourites: favourites,
      choice: c.choice,
      role: c.role,
      nullLabel: c.nullLabel,
      defaultOf: c.defaultOf,
    );
    final index = {for (final (i, e) in entries.indexed) e.ref: i};
    return ModelPickerData(
      title: pickerTitle(c.role),
      fetched: ModelCatalog.notifier.value.fetched != null,
      canAdd: providers.isNotEmpty,
      chat: c.role.chat,
      emptyNote: view.emptyNote,
      emptyTitle: view.noneTitle,
      quick: [
        for (final q in view.quick)
          ModelQuickData(
            providerId: q.providerId,
            title: q.title,
            subtitle: q.subtitle,
            selected: q.selected,
          ),
      ],
      models: [
        for (final e in entries)
          ModelCardData(
            providerId: e.providerId,
            providerName: e.providerName,
            modelId: e.info.id,
            name: e.info.displayName,
            searched: e.searched,
            hue: providerHue(e.providerName),
            context: e.info.context == null
                ? null
                : tokenCount(e.info.context!),
            price: modelPrice(e.info.inputCost, e.info.outputCost),
            toolCall: e.info.toolCall,
            reasoning: e.info.reasoning,
            readsImages: e.info.readsImages,
            makesImages: e.info.makesImages,
            transcribes: e.info.transcribes,
            speaks: e.info.speaks,
            custom: e.custom,
            selected:
                c.choice.providerId == e.providerId &&
                c.choice.modelId == e.info.id,
            favourite: starred.contains(e.ref),
          ),
      ],
      favourites: [for (final e in view.starred) index[e.ref]!],
      providers: [
        for (final MapEntry(key: id, value: name) in view.providers.entries)
          ModelProviderData(id: id, name: name),
      ],
    );
  }

  @override
  void toggleFavourite(String providerId, String modelId) => unawaited(
    _container.read(appSettingsProvider.notifier).toggleFavourite((
      providerId: providerId,
      modelId: modelId,
    )),
  );

  @override
  Future<SettingFormData> modelForm(
    String id,
    String? providerId,
    String? modelId,
    Map<String?, String?>? answers,
  ) async {
    final c = _at<ModelPickController>(id);
    final form = c == null
        ? null
        : modelFormFor(_reader, c.role, providerId: providerId, model: modelId);
    if (form == null) {
      return SettingFormData(title: "", answers: const {}, parts: const []);
    }
    return _formData(form, answers);
  }

  @override
  Future<FormSaveData?> submitModelForm(
    String id,
    String? providerId,
    String? modelId,
    Map<String?, String?> answers,
  ) async {
    final c = _at<ModelPickController>(id);
    final form = c == null
        ? null
        : modelFormFor(_reader, c.role, providerId: providerId, model: modelId);
    if (form == null) return null;
    try {
      await saveModel(_reader, form, _answersOf(answers));
      return null;
    } catch (e) {
      return _refusal(e);
    }
  }

  @override
  void deleteModel(String providerId, String modelId) => unawaited(
    _container
        .read(appSettingsProvider.notifier)
        .removeCustomModel(providerId, modelId),
  );

  BotStage get _stage => _container.read(botStageProvider);

  @override
  Future<Float64List?> botGeometry(String key) async => _stage.geometry(key);

  @override
  Future<Float64List?> botFrame(
    String instance,
    String key,
    int mood,
    bool live,
    bool thumbnail,
    double nowMs,
    double turnYaw,
    double turnPitch,
    double? pointerX,
    double? pointerY,
    double size,
  ) async => _stage.frame(
    instance,
    key,
    now: Duration(microseconds: (nowMs * 1000).round()),
    mood: BotMood.values[mood.clamp(0, BotMood.values.length - 1)],
    live: live,
    thumbnail: thumbnail,
    turn: ViewTurn(turnYaw, turnPitch),
    pointer: pointerX == null || pointerY == null ? null : (pointerX, pointerY),
    size: size,
  );

  @override
  void botTap(String instance, double nowMs) =>
      _stage.tap(instance, Duration(microseconds: (nowMs * 1000).round()));

  @override
  void botDrop(String instance) => _stage.drop(instance);

  @override
  Future<BotAvatarsData> botAvatars(String? agent) async {
    final (face, presets, imported) = await (
      agent == null
          ? Future<AgentFace?>.value()
          : _container.read(
              agentPictureProvider((project: null, name: agent)).future,
            ),
      _container.read(botAvatarPresetsProvider.future),
      _container.read(importedBotAvatarsProvider.future),
    ).wait;
    final initial = face?.bot;
    final entries = botAvatarEntries(presets, imported, initial: initial);
    return BotAvatarsData(
      entries: [
        for (final e in entries)
          BotAvatarEntryData(
            key: _stage.keyOf(e.definition),
            name: e.definition.name,
            colour: e.ownColour,
            removable: e.source == BotAvatarSource.imported,
          ),
      ],
      palette: [
        for (final s in BotPalette.all) BotSwatchData(name: s.name, rgb: s.rgb),
      ],
      selected: initial == null ? null : _stage.keyOf(initial.definition),
      selectedColour: initial?.colour,
    );
  }

  @override
  Future<BotImportData> importBotAvatars(String text) async {
    final result = BotAvatarImport.parse(text);
    switch (result) {
      case BotAvatarImportFailed(:final errors, :final hints, :final notes):
        return BotImportData(errors: errors, hints: hints, notes: notes);
      case BotAvatarImported(:final definitions, :final notes):
        await _container
            .read(importedBotAvatarsProvider.notifier)
            .add(definitions);
        return BotImportData(
          notes: notes,
          added: _stage.keyOf(definitions.last),
          count: definitions.length,
        );
    }
  }

  @override
  Future<void> deleteBotAvatar(String key) async {
    final definition = _stage.definition(key);
    if (definition == null) return;
    await _container
        .read(importedBotAvatarsProvider.notifier)
        .remove(definition.id);
  }

  @override
  Future<String> page(TextPageData opens) async => switch (opens.kind) {
    TextPageKind.privacyPolicy => bundledPrivacyPolicy,
    TextPageKind.inline => opens.text ?? "",
    TextPageKind.licences => await _licences,
    TextPageKind.skill => await _skill(opens.name ?? "", opens.project),
  };

  Future<String> _skill(String name, String? project) async => skillMarkdown(
    name,
    await skillDetail(
      _container.read(appConfigProvider),
      name,
      project: project,
    ),
  );

  /// Every library the app is built on, and its licence, as text: read
  /// once, the registry being fixed for the life of the process.
  static final Future<String> _licences = _readLicences();

  static Future<String> _readLicences() async {
    final parts = <String>[];
    await for (final entry in LicenseRegistry.licenses) {
      parts.add(
        "${entry.packages.join(", ")}\n\n"
        "${entry.paragraphs.map((p) => p.text).join("\n\n")}",
      );
    }
    return parts.join("\n\n———\n\n");
  }
}
