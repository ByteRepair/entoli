import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/scope.dart";
import "../../app/settings/spec.dart" show WidgetReader;
import "../../domain/llm_provider.dart";
import "../../domain/models.dart" show ModelChoice;
import "../../domain/settings/setting.dart";
import "../widgets/busy.dart";
import "../widgets/environment_section.dart";
import "../widgets/model_picker.dart";
import "../widgets/resettable_field.dart";
import "../widgets/thinking_slider.dart";

/// One setting at one level, drawn as the control its value wants: a
/// switch, a choice, a count, a model. Each reads its level through
/// [scopeOf], so what it shows is what that level holds, and writes back
/// through it.
///
/// Unset is offered where the level inherits — a project, a chat — or where
/// the key has no fallback even at the app's: the control then stands where
/// the level above does, with a reset back to it once this level picks.

/// The settings at [at], rebuilt as its documents change.
SettingsScope scopeOf(WidgetRef ref, ScopeAddress at) =>
    scopeAt(WidgetReader(ref), at);

bool _unsettable(SettingsScope scope, Setting setting) =>
    scope.parent != null || setting is! DefaultedSetting;

/// What this level holds where it may hold nothing, and what it answers
/// where it may not.
T? _value<T extends Object>(SettingsScope scope, Setting<T> setting) =>
    _unsettable(scope, setting) ? scope.own(setting) : scope.resolve(setting);

/// A switch over [setting] at [at], three-way where the level inherits.
class ScopedSwitch extends ConsumerWidget {
  const ScopedSwitch({
    super.key,
    required this.setting,
    required this.at,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.write,
  });

  final Setting<bool> setting;
  final ScopeAddress at;
  final String title;
  final String? subtitle;
  final bool enabled;

  /// Where a change goes instead of the level's document: a setting whose
  /// write has more to it than the key.
  final Future<void> Function(bool? value)? write;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    void set(bool? value) => guarded(
      context,
      () => write?.call(value) ?? scope.write(setting, value),
    );
    final effective = scope.resolve(setting) ?? false;
    final subtitle = this.subtitle;
    if (_unsettable(scope, setting)) {
      return InheritableSwitch(
        title: title,
        subtitle: subtitle,
        value: scope.own(setting),
        inherited: effective,
        enabled: enabled,
        onChanged: set,
      );
    }
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: effective,
      onChanged: enabled ? set : null,
    );
  }
}

/// A choice over [setting] at [at]: a dropdown, with an inherited entry at
/// a level that inherits, or a segmented button where [segmented].
class ScopedChoice<T extends Object> extends ConsumerWidget {
  const ScopedChoice({
    super.key,
    required this.setting,
    required this.at,
    required this.title,
    required this.options,
    this.unsetMeans,
    this.description,
    this.segmented = false,
    this.disabled = const {},
    this.write,
  });

  final Setting<T> setting;
  final ScopeAddress at;
  final String title;

  /// Each value offered, in order, and how it reads.
  final Map<T, String> options;

  /// What nothing set stands for where no level above says.
  final T? unsetMeans;
  final String? description;
  final bool segmented;
  final Set<T> disabled;
  final Future<void> Function(T? value)? write;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    void set(T? value) => guarded(
      context,
      () => write?.call(value) ?? scope.write(setting, value),
    );
    final value = _value(scope, setting);
    if (segmented) {
      return LabelledField(
        label: title,
        child: SegmentedButton<T>(
          segments: [
            for (final MapEntry(key: v, value: label) in options.entries)
              ButtonSegment(
                value: v,
                label: Text(label),
                enabled: !disabled.contains(v),
              ),
          ],
          selected: {?value},
          emptySelectionAllowed: value == null,
          onSelectionChanged: (picked) => set(picked.first),
        ),
      );
    }
    if (_unsettable(scope, setting)) {
      final inherited = scope.inherited(setting) ?? unsetMeans;
      return InheritableDropdown<T>(
        label: title,
        value: value,
        inherited: inherited == null ? null : options[inherited],
        options: options,
        disabled: disabled,
        onChanged: set,
      );
    }
    return LabelledField(
      label: title,
      child: DropdownButtonFormField<T>(
        key: ValueKey(value),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(helperText: description, helperMaxLines: 3),
        items: [
          for (final MapEntry(key: v, value: label) in options.entries)
            DropdownMenuItem(
              value: v,
              enabled: !disabled.contains(v),
              child: Text(label),
            ),
        ],
        onChanged: (picked) {
          if (picked != null) set(picked);
        },
      ),
    );
  }
}

/// A choice over ordered [stops] drawn as a slider, a thinking level the
/// first: the value stands where the level above does until this one
/// picks.
class ScopedLevels<T extends Object> extends ConsumerWidget {
  const ScopedLevels({
    super.key,
    required this.setting,
    required this.at,
    required this.title,
    required this.stops,
    this.unsetMeans,
    this.help,
  });

  final Setting<T> setting;
  final ScopeAddress at;
  final String title;
  final Map<T, String> stops;
  final T? unsetMeans;
  final String? help;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    final own = _value(scope, setting);
    final inherited = scope.inherited(setting) ?? unsetMeans;
    final shown = own ?? inherited ?? stops.keys.first;
    void set(T? value) => guarded(context, () => scope.write(setting, value));
    final slider = ThinkingSlider<T>(
      stops: stops,
      value: shown,
      onChanged: set,
      help: help,
    );
    return LabelledField(
      label: title,
      child: _unsettable(scope, setting) && own != null
          ? ResettableField(
              onReset: () => set(null),
              resetLabel: inherited == null
                  ? defaultOptionLabel
                  : "$defaultOptionLabel (${stops[inherited]})",
              child: slider,
            )
          : slider,
    );
  }
}

/// A count over [setting] at [at], from [stops] or every number from [min]
/// to [max].
class ScopedCount extends ConsumerWidget {
  const ScopedCount({
    super.key,
    required this.setting,
    required this.at,
    required this.title,
    this.stops,
    this.min = 0,
    this.max = 0,
    this.unsetMeans = 0,
  });

  final Setting<int> setting;
  final ScopeAddress at;
  final String title;
  final List<int>? stops;
  final int min;
  final int max;
  final int unsetMeans;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    void set(int? value) => guarded(context, () => scope.write(setting, value));
    final inherited = scope.inherited(setting) ?? unsetMeans;
    if (stops == null && !_unsettable(scope, setting)) {
      final value = (scope.resolve(setting) ?? inherited).clamp(min, max);
      return LabelledField(
        label: title,
        child: Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max > min ? max - min : null,
          label: "$value",
          onChanged: (v) => set(v.round()),
        ),
      );
    }
    return InheritableSlider(
      label: title,
      value: _value(scope, setting),
      stops: stops ?? [for (var i = min; i <= max; i++) i],
      inherited: inherited,
      onChanged: set,
    );
  }
}

/// A model over the pair of keys holding its provider and its id, both
/// written in one change.
class ScopedModel extends ConsumerWidget {
  const ScopedModel({
    super.key,
    required this.keys,
    required this.at,
    required this.title,
    required this.nullLabel,
    this.role = ModelRole.agent,
    this.defaultOf = LlmProviderConfig.chatDefaultOf,
    this.description,
    this.inherited,
  });

  final ({Setting<String> provider, Setting<String> model}) keys;
  final ScopeAddress at;
  final String title;
  final String nullLabel;
  final ModelRole role;
  final String? Function(LlmProviderConfig) defaultOf;
  final String? description;

  /// What nothing picked here falls back to, where a level above picks.
  final ModelChoice? inherited;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    return LabelledField(
      label: title,
      child: ModelPicker(
        choice: (
          providerId: scope.own(keys.provider),
          modelId: scope.own(keys.model),
        ),
        nullLabel: nullLabel,
        defaultOf: defaultOf,
        inherited: inherited,
        role: role,
        helperOffText: description,
        onChanged: (choice) => guarded(
          context,
          () => scope.writeAll({
            keys.provider: choice.providerId,
            keys.model: choice.modelId,
          }),
        ),
      ),
    );
  }
}

/// Name and value pairs at [at]: the environment a command runs under.
class ScopedEnvironment extends ConsumerWidget {
  const ScopedEnvironment({super.key, required this.setting, required this.at});

  final Setting<Map<String, String>> setting;
  final ScopeAddress at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = scopeOf(ref, at);
    return EnvironmentRows(
      env: scope.own(setting) ?? const {},
      onSaved: (entries) => scope.write(setting, entries),
    );
  }
}
