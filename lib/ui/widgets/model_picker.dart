import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/builtin/llm/hosted_models.dart";
import "../../data/builtin/llm/local_pool_client.dart" show OnDeviceProvider;
import "../../domain/llm_provider.dart";
import "../../domain/model_capability.dart";
import "../../domain/model_registry.dart";
import "../../domain/models.dart";
import "../../providers.dart";
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
    final providers = ref.watch(appSettingsProvider.select((s) => s.llmProviders));
    final listed = ref.watch(sortedModelsProvider).value ?? const <ModelOption>[];
    final onDevice = ref.watch(onDeviceModelsProvider);
    final none = choice.providerId == null && choice.modelId == null;
    final nullEntry =
        inherited == null ? nullLabel : "$nullLabel (${_name(providers, listed, inherited!)})";
    final defaultEntry = _defaultEntry(providers, defaultOf);
    return ResettableField(
      resetLabel: defaultEntry == null
          ? nullLabel
          : "${defaultEntry.displayName} - Default (${defaultOf(defaultEntry)})",
      onReset: () => onChanged(defaultEntry == null
          ? (providerId: null, modelId: null)
          : (providerId: defaultEntry.id, modelId: null)),
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
            helperText: none ? helperOffText ?? _inheritedHelper(providers, listed) : null,
            helperMaxLines: 3,
            suffixIcon: const Icon(Icons.chevron_right),
          ),
          child: Text(_label(providers, listed, onDevice),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  String? _inheritedHelper(List<LlmProviderConfig> providers, List<ModelOption> listed) =>
      inherited == null ? null : "Using ${_name(providers, listed, inherited!)}";

  /// What the field reads as. A Default whose provider is gone, or names no
  /// default, has nothing to resolve to and reads as the null entry, whose
  /// helper names what it inherits; a model
  /// is named by what the catalog calls it, its id where nothing does.
  String _label(List<LlmProviderConfig> providers, List<ModelOption> listed,
      OnDeviceProvider onDevice) {
    // A voice model is named by what the device says of it, since no endpoint
    // lists it.
    if (role.voice && choice.providerId == onDevice.id) {
      final model = choice.modelId;
      return (model == null ? null : onDevice.resolve<Model>(model, ModelHost.resolving()))
              ?.info
              .displayName ??
          nullLabel;
    }
    final provider = providers.firstWhereOrNull((p) => p.id == choice.providerId);
    if (choice.modelId == null) {
      final model = provider == null ? null : defaultOf(provider);
      return model == null ? nullLabel : "${provider!.displayName} - Default ($model)";
    }
    // A provider gone from settings, and from the on-device endpoints, leaves
    // nothing that could answer: as good as nothing chosen.
    final reachable = provider != null ||
        choice.providerId == null ||
        listed.any((m) => m.providerId == choice.providerId);
    return reachable ? _name(providers, listed, choice) : nullLabel;
  }
}

/// A chosen model by the name the catalog gives it, then the on-device list's,
/// then its id; "the app default" where nothing is chosen.
String _name(List<LlmProviderConfig> providers, List<ModelOption> listed, ModelChoice choice) {
  final provider = providers.firstWhereOrNull((p) => p.id == choice.providerId);
  final model = choice.modelId ??
      (provider == null ? null : LlmProviderConfig.chatDefaultOf(provider));
  if (model == null) return "the app default";
  return modelInfoOf(provider, model)?.name ??
      listed
          // A model stored without its provider, as an older chat's was.
          .firstWhereOrNull((m) =>
              m.modelId == model &&
              (choice.providerId == null || m.providerId == choice.providerId))
          ?.label ??
      model;
}

/// The first provider whose Default entry the catalog shows, or null when
/// none of them names one. Reset anchors here rather than on the first
/// provider, since only providers naming one have an entry to land on.
LlmProviderConfig? _defaultEntry(List<LlmProviderConfig> providers,
        String? Function(LlmProviderConfig) defaultOf) =>
    providers.firstWhereOrNull((p) => defaultOf(p) != null);
