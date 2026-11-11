import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/controller.dart";
import "../../app/settings/scope.dart";
import "../../app/settings/settings.dart";
import "../../app/settings/spec.dart";
import "../../core/formatting.dart";
import "../../core/log.dart";
import "../../data/builtin/llm/hosted_models.dart" show ModelHost;
import "../../data/privacy_policy_data.dart";
import "../../domain/llm_provider.dart";
import "../../domain/model_registry.dart" show ModelCatalog, modelInfoOf;
import "../../providers.dart";
import "../../app/prompts/skill_files.dart";
import "../bot_avatar/face_png.dart";
import "../widgets/model_catalog_page.dart" show catalogEntries;

/// Every page the native settings offer, as rows, and the controller each
/// row was sent from, by its id: what an intent naming a row acts on.
typedef NativeSettingsPages = ({
  SettingsSnapshot snapshot,
  Map<String, SettingController> controllers,
});

/// An agent of the default project's face as a PNG, painted once its face
/// is read: what the native agents list shows beside each name.
final agentFacePngProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, name) async {
      final face = await ref.watch(
        agentPictureProvider((project: null, name: name)).future,
      );
      return agentFacePng(face);
    });

/// The pages this platform offers, built through the provider's ref and
/// rebuilt whenever anything one reads changes. Welcome is the tour, not
/// settings, and stays the app's own page.
final nativeSettingsProvider = Provider<NativeSettingsPages>((ref) {
  final reader = RefReader(ref);
  final schema = ref.watch(settingsSchemaProvider);
  final controllers = <String, SettingController>{};
  final providers = ref.watch(appSettingsProvider).llmProviders;
  Uint8List? face(String name) => ref.watch(agentFacePngProvider(name)).value;
  final pages = [
    for (final page in SettingsPageId.values)
      if (page != SettingsPageId.welcome &&
          (!page.listed || pageOffered(reader, page)))
        SettingsPageData(
          key: SettingsPageKey.values.byName(page.name),
          title: page.title,
          groupStart: page.groupStart,
          listed: page.listed,
          sections: [
            for (final section in buildPage(
              reader,
              schema,
              page,
              const AppAddress(),
            ))
              SettingsSectionData(
                id: section.spec.id,
                title: section.spec.title,
                detail: section.description,
                rows: [
                  for (final setting in section.settings)
                    ..._rows(setting, controllers, providers, face),
                ],
              ),
          ],
        ),
  ];
  return (snapshot: SettingsSnapshot(pages: pages), controllers: controllers);
});

/// [c] as the rows that carry it: its own, then a group's children and an
/// accessory, each naming it their parent.
/// Each agent's face, by its name; null for none, or not painted yet.
typedef _Faces = Uint8List? Function(String name);

List<SettingRowData> _rows(
  SettingController c,
  Map<String, SettingController> controllers,
  List<LlmProviderConfig> providers,
  _Faces faces, {
  String? parent,
  bool accessory = false,
}) {
  controllers[c.id] = c;
  return [
    _row(c, providers, faces, parent: parent, accessory: accessory),
    if (c case GroupController(:final children))
      for (final child in children)
        if (child.visible)
          ..._rows(child, controllers, providers, faces, parent: c.id),
    if (c.accessory case final action?)
      ..._rows(
        action,
        controllers,
        providers,
        faces,
        parent: c.id,
        accessory: true,
      ),
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
    : SettingNoticeData(title: notice.title, message: notice.message);

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
  appIcon: switch (option.look) {
    AppIconLook(:final icon) => icon.name,
    _ => null,
  },
);

/// What a model pick's field reads as: the null entry, a provider's Default
/// and the model it resolves to, or the model by the catalog's name for it.
String _modelLabel(ModelPickController c, List<LlmProviderConfig> providers) {
  final (:providerId, :modelId) = c.choice;
  if (providerId == null && modelId == null) return c.nullLabel;
  final provider = providers.where((p) => p.id == providerId).firstOrNull;
  if (modelId == null) {
    final model = provider == null ? null : c.defaultOf(provider);
    return model == null
        ? c.nullLabel
        : "${provider!.displayName} - Default ($model)";
  }
  return modelInfoOf(provider, modelId)?.name ?? modelId;
}

SettingRowData _row(
  SettingController c,
  List<LlmProviderConfig> providers,
  _Faces faces, {
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
        ..unsettable = c.unsettable
        ..commitOnEnd = c.commitOnEnd;
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
      row
        ..kind = SettingKind.modelPick
        ..modelLabel = _modelLabel(c, providers)
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
    case NoticeController():
      row
        ..kind = SettingKind.notice
        ..notice = [
          for (final line in c.lines)
            SettingLineData(text: line.text, url: line.url?.toString()),
        ]
        ..tone = _tone(c.tone);
    case CollectionController():
      row
        ..kind = SettingKind.collection
        ..items = [
          for (final item in c.rows)
            SettingItemData(
              title: item.title,
              subtitle: item.subtitle,
              error: item.error,
              icon: _icon(item.glyph),
              tone: _tone(item.tone),
              on: item.on,
              opens: item.opens,
              image: c.hint == UiHint.agents && item.id != null
                  ? faces(item.id!)
                  : null,
              actions: [
                for (final action in item.actions)
                  SettingItemActionData(
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
        ..takesImages = c.takesImages
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
              tags: switch (item.facts) {
                null => const [],
                final f => [
                  if (f.parameters case final p?) "$p params",
                  ?f.languages,
                  if (f.bytes case final b?) formatSize(b),
                  ?f.quantisation,
                  if (f.context case final n?) "$n context",
                  if (f.voices case final v?) plural(v, "voice"),
                  ?f.licence,
                ],
              },
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
              opens: info.opens?.name,
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
                stage: activity.stage.name,
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
        ..label = c.deleteConfirm.title
        ..summary = c.deleteConfirm.message;
  }
  return row;
}

List<FormOptionData> _formOptions(List<FormOption> options) => [
  for (final option in options)
    FormOptionData(
      answer: option.answer,
      label: option.label,
      help: option.help,
    ),
];

/// The native settings' end of the app: sends every page as it changes, and
/// runs what the client says the user did against the controller the row
/// was sent from.
class SettingsBridge implements SettingsIntents {
  SettingsBridge(this._container) {
    SettingsIntents.setUp(this);
    _sending = _container.listen<NativeSettingsPages>(
      nativeSettingsProvider,
      (_, pages) => _send(pages),
      // A page that cannot be built says why rather than taking the shell
      // down with it.
      onError: (e, _) => logFailure("settings", "building the pages", e),
      fireImmediately: true,
    );
  }

  final ProviderContainer _container;
  final _native = NativeSettings();
  late final ProviderSubscription<NativeSettingsPages> _sending;

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
    _sending.close();
    SettingsIntents.setUp(null);
  }

  T? _at<T extends SettingController>(String id) {
    final c = _container.read(nativeSettingsProvider).controllers[id];
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
  void setText(String id, String text) => _at<TextController>(id)?.set(text);

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
  Future<SettingFormData> form(
    String id,
    int? index,
    Map<String?, String?>? answers,
  ) async {
    final c = _at<CollectionController>(id);
    final form = c?.typed(
      <V>(c) => c.form?.call(index == null ? null : c.items[index]),
    );
    if (form == null) {
      return SettingFormData(title: "", answers: const {}, parts: const []);
    }
    final now = answers == null
        ? {...form.initial}
        : {
            for (final MapEntry(:key, :value) in answers.entries)
              ?key: value ?? "",
          };
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
            ),
            FormChoice() => FormPartData(
              kind: FormPartKind.choice,
              id: part.id,
              label: part.label,
              options: _formOptions(part.options),
              enabled: part.enabled,
              segmented: part.segmented,
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
            FormList() => FormPartData(
              kind: FormPartKind.list,
              id: part.id,
              label: part.label,
              hint: part.hint,
              helper: part.helper,
              error: part.error,
              enabled: part.enabled,
            ),
            FormMulti() => FormPartData(
              kind: FormPartKind.multi,
              id: part.id,
              label: part.label,
              error: part.error,
              options: _formOptions(part.options),
              enabled: part.enabled,
            ),
            FormNote(:final text) => FormPartData(
              kind: FormPartKind.note,
              label: text,
            ),
          },
      ],
    );
  }

  @override
  Future<SettingNoticeData?> submitForm(
    String id,
    int? index,
    Map<String?, String?> answers,
  ) async {
    try {
      await _at<CollectionController>(id)?.submit({
        for (final MapEntry(:key, :value) in answers.entries) ?key: value ?? "",
      }, index: index);
      return null;
    } catch (e) {
      return SettingNoticeData(message: "$e");
    }
  }

  @override
  void catalog(String id, String item, String op) {
    final c = _at<CatalogController>(id);
    if (c == null) return;
    switch (op) {
      case "download":
        c.download(item);
      case "cancel":
        c.cancel(item);
      case "delete":
        c.delete(item);
      case "add":
        c.add();
    }
  }

  @override
  void pairing(String id, String op) {
    final c = _at<PairingController>(id);
    if (c == null) return;
    switch (op) {
      case "openWindow":
        unawaited(c.openWindow());
      case "closeWindow":
        c.closeWindow();
      case "match":
        c.confirm(true);
      case "mismatch":
        c.confirm(false);
      case "scan":
        unawaited(c.scan());
      default:
        c.cancel();
    }
  }

  @override
  Future<String?> pairWith(String id, String code) async {
    try {
      await _at<PairingController>(id)?.join(code);
      return null;
    } catch (e) {
      return "$e";
    }
  }

  @override
  Future<String> createInvite(String id) async =>
      await _at<PairingController>(id)?.createInvite() ?? "";

  @override
  void setup(String id, String op) {
    final c = _at<SetupController>(id);
    if (c == null) return;
    switch (op) {
      case "setUp":
        unawaited(c.setUp());
      case "import":
        unawaited(c.import());
      case "delete":
        unawaited(c.delete());
    }
  }

  @override
  Future<List<String>> models(String id) async {
    final c = _at<ModelPickController>(id);
    if (c == null) return const [];
    final listed = _container.read(sortedModelsProvider).value ?? const [];
    final serving = _container.read(modelProvidersProvider);
    final cuts = _container.read(voiceProvider).hasModelCatalog;
    final entries = catalogEntries(
      ModelCatalog.notifier.value,
      serving,
      listed,
      role: c.role,
      host: ModelHost.resolving(cutsUtterances: cuts),
    );
    String entry(
      String? providerId,
      String? modelId,
      String label,
      String in_,
    ) => "${providerId ?? ""}\u0000${modelId ?? ""}\u0000$label\u0000$in_";
    return [
      entry(null, null, c.nullLabel, ""),
      for (final provider in _container.read(appSettingsProvider).llmProviders)
        if (c.defaultOf(provider) case final model?)
          entry(
            provider.id,
            null,
            "${provider.displayName} - Default ($model)",
            "",
          ),
      for (final e in entries)
        entry(e.providerId, e.info.id, e.info.displayName, e.providerName),
    ];
  }

  @override
  Future<String> page(String opens) async => switch (opens) {
    "privacyPolicy" => bundledPrivacyPolicy,
    final skill when skill.startsWith("skill:") => await _skill(
      skill.substring("skill:".length),
    ),
    _ => await _licences(),
  };

  /// A skill as its view page tells it: what it is for, what its folder is
  /// wrong about, its instructions, and its other files.
  Future<String> _skill(String name) async {
    final detail = await skillDetail(_container.read(appConfigProvider), name);
    if (detail == null) {
      return "The skill's files could not be read. It may have been removed.";
    }
    final md = detail.skillMd;
    return [
      "# $name",
      ?md?.description,
      if (detail.problems.isNotEmpty)
        "**Not loaded:** ${detail.problems.join("; ")}",
      ?md?.body,
      if (detail.files.isNotEmpty)
        "**Files**\n\n${[for (final (path, bytes) in detail.files) "- $path (${formatSize(bytes.length)})"].join("\n")}",
    ].join("\n\n");
  }

  /// Every library the app is built on, and its licence, as text.
  static Future<String> _licences() async {
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
