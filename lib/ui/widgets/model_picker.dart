import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/providers/provider.dart" show LlmProvider;
import "../../domain/llm_provider.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../../app/model_picker.dart"
    show missingModelLabel, modelFieldError, modelFieldLabel, modelName;
import "model_catalog_page.dart";
import "resettable_field.dart";

export "model_catalog_page.dart" show ModelRole;

/// One model out of every configured provider, or the null entry above them,
/// picked on the [ModelCatalogPage] the field opens.
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
/// null entry is what [nullLabel] says and resolves to nothing. [role] is what
/// the model is for, which decides what the catalog offers.
class ModelPicker extends ConsumerWidget {
  const ModelPicker({
    super.key,
    required this.choice,
    required this.onChanged,
    required this.nullLabel,
    this.defaultOf = LlmProviderConfig.chatDefaultOf,
    this.inherited,
    this.helperOffText,
    this.role = ModelRole.agent,
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

  final ModelRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(
      appSettingsProvider.select((s) => s.llmProviders),
    );
    final models = ref.watch(sortedModelsProvider);
    final listed = models.value ?? const <ModelOption>[];
    final serving = ref.watch(modelProvidersProvider);
    final none = choice.providerId == null && choice.modelId == null;
    final missing = modelFieldError(
      choice: choice,
      role: role,
      loaded: models.hasValue,
      listed: listed,
      serving: serving,
    );
    final nullEntry = inherited == null
        ? nullLabel
        : "$nullLabel (${modelName(providers, listed, inherited!)})";
    final defaultEntry = _defaultEntry(providers, defaultOf);
    return ResettableField(
      resetLabel: defaultEntry == null
          ? nullLabel
          : "${defaultEntry.displayName} - Default (${defaultOf(defaultEntry)})",
      onReset: () => onChanged(
        defaultEntry == null
            ? (providerId: null, modelId: null)
            : (providerId: defaultEntry.id, modelId: null),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () async {
          final picked = await Navigator.of(context).push<ModelChoice>(
            MaterialPageRoute(
              builder: (_) => ModelCatalogPage(
                choice: choice,
                nullEntry: nullEntry,
                defaultOf: defaultOf,
                role: role,
              ),
            ),
          );
          if (picked != null) onChanged(picked);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            helperText: none
                ? helperOffText ?? _inheritedHelper(providers, listed)
                : null,
            helperMaxLines: 3,
            errorText: missing,
            errorMaxLines: 2,
            suffixIcon: const Icon(Icons.chevron_right),
          ),
          child: Text(
            missing != null
                ? missingModelLabel
                : _label(providers, listed, serving),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  String? _inheritedHelper(
    List<LlmProviderConfig> providers,
    List<ModelOption> listed,
  ) => inherited == null
      ? null
      : "Using ${modelName(providers, listed, inherited!)}";

  String _label(
    List<LlmProviderConfig> providers,
    List<ModelOption> listed,
    List<LlmProvider> serving,
  ) => modelFieldLabel(
    choice: choice,
    role: role,
    nullLabel: nullLabel,
    defaultOf: defaultOf,
    providers: providers,
    listed: listed,
    serving: serving,
  );
}

/// The first provider whose Default entry the catalog shows, or null when
/// none of them names one. Reset anchors here rather than on the first
/// provider, since only providers naming one have an entry to land on.
LlmProviderConfig? _defaultEntry(
  List<LlmProviderConfig> providers,
  String? Function(LlmProviderConfig) defaultOf,
) => providers.firstWhereOrNull((p) => defaultOf(p) != null);
