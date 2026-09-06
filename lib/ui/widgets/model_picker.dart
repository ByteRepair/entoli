import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/llm_provider.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// One model out of every configured provider, or the null entry above them.
///
/// Three states, spelled by the stored [ModelChoice]:
///
/// - **None/Off** — `(null, null)`: no provider, or the feature explicitly
///   off. [nullLabel] names what that means on the field this picker serves.
/// - **Default** — `(providerId, null)`: the provider's recommended model,
///   resolved at turn time so a preset's default can change without anything
///   stored. One entry per provider, named `<provider> - Default (<model>)`
///   so it is obvious what picking it means.
/// - **Specific** — both halves set: one model, as before.
///
/// [defaultOf] says which provider field the Default entries resolve to — the
/// chat default for the LLM field, the light one for title, memory and
/// classifier. [inherited] is what the null entry resolves to at the level
/// above (the chat override's "Default (app default)"); where it is null the
/// null entry is what [nullLabel] says and resolves to nothing.
class ModelPicker extends StatelessWidget {
  const ModelPicker({
    super.key,
    required this.choice,
    required this.onChanged,
    required this.nullLabel,
    this.defaultOf = LlmProviderConfig.chatDefaultOf,
    this.inherited,
    this.helperOffText,
  });

  final ModelChoice choice;
  final ValueChanged<ModelChoice> onChanged;

  /// What the entry storing nothing is called. "None" where nothing exists,
  /// "Off" where a feature is optional, "Default" where it inherits.
  final String nullLabel;

  /// Which provider field the Default entries resolve to — the chat default
  /// for the LLM field, the light one for title, memory and classifier.
  final String? Function(LlmProviderConfig) defaultOf;

  final ModelChoice? inherited;

  /// Shown under the field while the null entry is picked, saying what the
  /// feature this picker serves does with nothing chosen. The optional
  /// pickers' "Off, ..." lines.
  final String? helperOffText;


  @override
  Widget build(BuildContext context) {
    return _Models((providers, models) {
      final none = choice.providerId == null && choice.modelId == null;
      return ResettableField(
        resetLabel: providers.isEmpty ? nullLabel : _defaultLabel(providers),
        onReset: () => onChanged(_resetTarget(providers)),
        child: _dropdown(
          providers: providers,
          models: models,
          choice: choice,
          onChanged: onChanged,
          nullLabel: nullLabel,
          defaultOf: defaultOf,
          inherited: inherited,
          helperText: none ? helperOffText ?? _inheritedHelper(models) : null,
        ),
      );
    });
  }

  String? _inheritedHelper(List<ModelOption> models) =>
      inherited == null ? null : "Using ${_inheritedName(models, inherited)}";

  /// Where reset lands: the first Default entry the dropdown shows — the
  /// first provider that names one — or the null entry when there is nothing
  /// to have a default.
  ModelChoice _resetTarget(List<LlmProviderConfig> providers) {
    final provider = _defaultEntry(providers);
    return provider == null
        ? (providerId: null, modelId: null)
        : (providerId: provider.id, modelId: null);
  }

  String _defaultLabel(List<LlmProviderConfig> providers) {
    final provider = _defaultEntry(providers);
    if (provider == null) return nullLabel;
    return "${provider.displayName} - Default (${defaultOf(provider)})";
  }
}

/// What the null entry resolves to at the level above, named for the helper
/// line and the popup's `Default (…)` entry: the matched model's label, the
/// stored model id, or "the app default" when nothing is known.
String _inheritedName(List<ModelOption> models, ModelChoice? inherited) {
  final option = models.firstWhereOrNull((m) =>
      m.modelId == inherited?.modelId &&
      (inherited?.providerId == null || m.providerId == inherited?.providerId));
  return option != null
      ? (option.label ?? option.modelId)
      : inherited?.modelId ?? "the app default";
}

/// The first provider whose Default entry the dropdown shows, or null when
/// none of them names one. Reset anchors here rather than on the first
/// provider, since only providers naming one have an entry to land on.
LlmProviderConfig? _defaultEntry(List<LlmProviderConfig> providers) =>
    providers.firstWhereOrNull((p) => p.defaultModelId != null);

/// What a picker's dropdown shows, built over the configured providers and the
/// models they offer. The two things arrive together: a provider with no models
/// listed and none answered still shows its Default entry, naming what it
/// resolves to, and a model from a provider no longer configured is matched
/// against what is there rather than trusted.
typedef _DropdownBuilder = Widget Function(
    List<LlmProviderConfig> providers, List<ModelOption> models);

class _Models extends ConsumerWidget {
  const _Models(this.builder);

  final _DropdownBuilder builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(appSettingsProvider.select((s) => s.llmProviders));
    return ref.watch(sortedModelsProvider).when(
          data: (models) => builder(providers, models),
          loading: () => const Row(
            children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text("Loading models..."),
            ],
          ),
          error: (e, _) => Text("Failed to load models: $e"),
        );
  }
}

DropdownButtonFormField<ModelChoice> _dropdown({
  required List<LlmProviderConfig> providers,
  required List<ModelOption> models,
  required ModelChoice choice,
  required ValueChanged<ModelChoice> onChanged,
  required String nullLabel,
  required String? Function(LlmProviderConfig) defaultOf,
  required ModelChoice? inherited,
  required String? helperText,
}) {
  final nullEntry = inherited == null
      ? nullLabel
      : "$nullLabel (${_inheritedName(models, inherited)})";
  return DropdownButtonFormField<ModelChoice>(
    initialValue: _match(providers, models, choice, defaultOf),
    isExpanded: true,
    decoration: InputDecoration(helperText: helperText),
    // The closed field names the entry; the popup entry says what a Default
    // resolves to beside it. Without the builder the closed state would show
    // the whole "Default (inherited)" string, which is popup detail.
    selectedItemBuilder: (context) => [
      Text(nullLabel),
      for (final provider in providers)
        if (defaultOf(provider) != null) Text("${provider.displayName} - Default"),
      for (final m in models) Text(m.label ?? m.modelId),
    ],
    items: [
      DropdownMenuItem<ModelChoice>(
        value: (providerId: null, modelId: null),
        child: Text(nullEntry),
      ),
      // One Default entry per provider that names one, saying the model it
      // resolves to. A provider without one has nothing to resolve to, so it
      // offers its models alone.
      for (final provider in providers)
        if (defaultOf(provider) != null)
          DropdownMenuItem<ModelChoice>(
            value: (providerId: provider.id, modelId: null),
            child: Text("${provider.displayName} - Default (${defaultOf(provider)})"),
          ),
      for (final m in models)
        DropdownMenuItem<ModelChoice>(
          value: (providerId: m.providerId, modelId: m.modelId),
          child: Text(m.label ?? m.modelId),
        ),
    ],
    onChanged: (c) =>
        onChanged((providerId: c?.providerId, modelId: c?.modelId)),
  );
}

/// A stored choice is matched against the items rather than trusted: one whose
/// model the backend no longer offers reads as its provider's Default — or,
/// where the provider is gone too, as the null entry — or the dropdown asserts
/// on having no item for its value.
ModelChoice? _match(
  List<LlmProviderConfig> providers,
  List<ModelOption> models,
  ModelChoice choice,
  String? Function(LlmProviderConfig) defaultOf,
) {
  // The Default entry a named provider resolves to, or nothing when it is
  // gone or names no default.
  ModelChoice? defaultChoiceOf(String? providerId) {
    final provider = providers.firstWhereOrNull((p) => p.id == providerId);
    return provider != null && defaultOf(provider) != null
        ? (providerId: provider.id, modelId: null)
        : null;
  }

  if (choice.providerId == null && choice.modelId == null) {
    return (providerId: null, modelId: null);
  }
  if (choice.modelId == null) {
    // A Default choice: its provider's Default entry, where the provider is
    // still there and names a default. One without — a custom provider, or
    // one whose preset names nothing — has nothing to resolve to, so it reads
    // as the null entry rather than as an item nothing renders.
    return defaultChoiceOf(choice.providerId) ?? (providerId: null, modelId: null);
  }
  // A specific model is matched by its own pair: the provider it rides with
  // is the one the backend offered it under, not one from settings. One the
  // backend no longer offers falls back to its provider's Default entry where
  // the provider is configured and names one — a model that has gone is not
  // nothing chosen — and the null entry where it is not.
  final found = models.firstWhereOrNull((m) =>
      m.modelId == choice.modelId &&
      (choice.providerId == null || m.providerId == choice.providerId));
  if (found != null) {
    return (providerId: found.providerId, modelId: found.modelId);
  }
  return defaultChoiceOf(choice.providerId) ?? (providerId: null, modelId: null);
}