import "../../domain/llm_provider.dart";
import "../../domain/models.dart" show ModelChoice;
import "../../domain/settings/setting.dart";
import "../model_role.dart";
import "controller.dart";

/// Controllers over one key at the context's level: what most settings
/// are. Unset is on offer where the level inherits — a project, a chat — or
/// where the key has no fallback at the app's level; [unsetMeans] then says
/// what it stands for where nothing above does.
extension BindSetting on SettingContext {
  bool _unsettable(Setting setting) =>
      scope.parent != null || setting is! DefaultedSetting;

  T? _value<T extends Object>(Setting<T> setting) =>
      _unsettable(setting) ? scope.own(setting) : scope.resolve(setting);

  ToggleController toggle(
    Setting<bool> setting, {
    String? description,
    bool visible = true,
    bool enabled = true,
    bool? shown,
    Future<void> Function(bool? value)? write,
    SettingNotice? Function(bool? value)? after,
  }) {
    final unsettable = _unsettable(setting);
    return ToggleController(
      spec,
      value: _value(setting),
      effective: shown ?? scope.resolve(setting) ?? false,
      unsettable: unsettable,
      description: description,
      visible: visible,
      enabled: enabled,
      onSet: (value) async {
        await (write?.call(value) ?? scope.write(setting, value));
        return after?.call(value);
      },
    );
  }

  ChoiceController<T> choice<T extends Object>(
    Setting<T> setting,
    List<SettingOption<T>> options, {
    T? unsetMeans,
    String? description,
    String? footnote,
    bool visible = true,
    Future<void> Function(T? value)? write,
  }) {
    final meaning = scope.inherited(setting) ?? unsetMeans;
    final label = options.where((o) => o.value == meaning).firstOrNull?.label;
    return ChoiceController<T>(
      spec,
      options: options,
      value: _value(setting),
      unsettable: _unsettable(setting),
      inheritedLabel: label,
      inherited: meaning,
      description: description,
      footnote: footnote,
      visible: visible,
      onSet: (value) async {
        await (write?.call(value) ?? scope.write(setting, value));
        return null;
      },
    );
  }

  RangeController range(
    Setting<int> setting, {
    List<int>? stops,
    int? min,
    int? max,
    int? unsetMeans,
    String? description,
    String? footnote,
    bool visible = true,
  }) => RangeController(
    spec,
    value: _value(setting),
    unsettable: _unsettable(setting),
    inherited: scope.inherited(setting) ?? unsetMeans ?? 0,
    stops: stops,
    min: min,
    max: max,
    description: description,
    footnote: footnote,
    visible: visible,
    onSet: (value) async {
      await scope.write(setting, value);
      return null;
    },
  );

  KeyValuesController keyValues(
    Setting<Map<String, String>> setting, {
    String? description,
  }) => KeyValuesController(
    spec,
    entries: scope.own(setting) ?? const {},
    description: description,
    onSet: (entries) => scope.write(setting, entries),
  );

  /// A model over the pair of keys holding its provider and its id: both
  /// are written in one change.
  ModelPickController model(
    ({Setting<String> provider, Setting<String> model}) keys, {
    required String nullLabel,
    String? Function(LlmProviderConfig) defaultOf =
        LlmProviderConfig.chatDefaultOf,
    ModelRole role = ModelRole.agent,
    String? description,
    bool visible = true,
    Future<void> Function(ModelChoice choice)? write,
    ModelChoice? choice,
    ModelChoice? inherited,
  }) => ModelPickController(
    spec,
    inherited: inherited,
    choice:
        choice ??
        (providerId: scope.own(keys.provider), modelId: scope.own(keys.model)),
    nullLabel: nullLabel,
    defaultOf: defaultOf,
    role: role,
    description: description,
    visible: visible,
    onSet: (choice) =>
        write?.call(choice) ??
        scope.writeAll({
          keys.provider: choice.providerId,
          keys.model: choice.modelId,
        }),
  );
}
