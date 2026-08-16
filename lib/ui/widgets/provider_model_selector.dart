import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// [ProviderModelSelector] over the backend's model list, with the waiting and
/// failure states both pages would otherwise spell out themselves.
class ModelPicker extends StatelessWidget {
  const ModelPicker({
    super.key,
    required this.choice,
    required this.onChanged,
    this.inherited,
  });

  final ModelChoice choice;
  final ValueChanged<ModelChoice> onChanged;
  final ModelChoice? inherited;

  @override
  Widget build(BuildContext context) => _Models((models) => ProviderModelSelector(
        models: models,
        choice: choice,
        onChanged: onChanged,
        inherited: inherited,
      ));
}

/// One model out of all of them, or none at all. Unlike [ProviderModelSelector]
/// there is no level below to inherit the other half, so a provider and a model
/// are picked together as one entry.
class OptionalModelPicker extends StatelessWidget {
  const OptionalModelPicker({
    super.key,
    required this.choice,
    required this.onChanged,
    required this.offLabel,
    this.helperText,
  });

  final ModelChoice choice;
  final ValueChanged<ModelChoice> onChanged;

  /// What the entry storing nothing is called — this is off, not inherited.
  final String offLabel;
  final String? helperText;

  @override
  Widget build(BuildContext context) => _Models((models) {
        if (models.isEmpty) return const Text(_noModelsLabel);
        final sorted = _byLabel(models);
        // Matched against the list rather than rebuilt, so a stored pair the
        // backend no longer offers reads as off instead of tripping the
        // dropdown's "exactly one item" assert.
        final selected = sorted.firstWhereOrNull(
            (m) => m.providerId == choice.providerId && m.modelId == choice.modelId);
        return DropdownButtonFormField<ModelOption?>(
          initialValue: selected,
          isExpanded: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: helperText,
          ),
          items: [
            DropdownMenuItem<ModelOption?>(value: null, child: Text(offLabel)),
            for (final m in sorted)
              DropdownMenuItem<ModelOption?>(value: m, child: Text(_label(m))),
          ],
          onChanged: (m) => onChanged((providerId: m?.providerId, modelId: m?.modelId)),
        );
      });
}

/// The configured models, once they are known. Every picker here needs the
/// same two answers to "not yet" and "that failed".
class _Models extends ConsumerWidget {
  const _Models(this.builder);

  final Widget Function(List<ModelOption> models) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(availableModelsProvider).when(
            data: builder,
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

const _noModelsLabel = "No models available.";

/// What a model is called in a list, and the order they are listed in. Every
/// field here shows the same models, so they cannot disagree on either.
String _label(ModelOption m) => m.label ?? m.modelId;

List<ModelOption> _byLabel(Iterable<ModelOption> models) => [...models]
  ..sort((a, b) => _label(a).toLowerCase().compareTo(_label(b).toLowerCase()));

/// The provider + model pair, as picked in the UI. Either half being null
/// means [defaultOptionLabel]: inherit from the level above.
typedef ModelChoice = ({String? providerId, String? modelId});

/// Paired provider and model dropdowns, used by both the app-level settings
/// and the per-chat override. The caller owns the values; this only enforces
/// the rules they share:
///
///  - `Default` leads each list and stores null.
///  - Providers are listed alphabetically, models alphabetically by label.
///  - A model is only ever reported alongside the provider that offers it.
///  - A stored model the backend no longer offers reads as `Default` rather
///    than tripping the dropdown's "exactly one item" assert.
class ProviderModelSelector extends StatelessWidget {
  const ProviderModelSelector({
    super.key,
    required this.models,
    required this.choice,
    required this.onChanged,
    this.inherited,
  });

  final List<ModelOption> models;
  final ModelChoice choice;
  final ValueChanged<ModelChoice> onChanged;

  /// What `Default` resolves to, named under each field. Also decides which
  /// models to list while the provider itself is on `Default`.
  final ModelChoice? inherited;

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) {
      return const Text(_noModelsLabel);
    }

    final providerIds = models.map((m) => m.providerId).toSet().toList()..sort();
    // A stored model without its provider still names one: whoever offers it.
    final providerId = choice.providerId ?? optionFor(models, choice.modelId)?.providerId;
    // On Default, list the models of the provider that will actually be used.
    // With nothing to inherit there is no such provider, and guessing one
    // would make Default mean something that shifts as providers come and go.
    final listed = providerId ?? inherited?.providerId;
    final forProvider = _byLabel(models.where((m) => m.providerId == listed));

    final modelId = forProvider.any((m) => m.modelId == choice.modelId) ? choice.modelId : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResettableField(
          isDefault: providerId == null,
          onReset: () => onChanged((providerId: null, modelId: null)),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Provider",
              border: const OutlineInputBorder(),
              helperText: _helper(providerId, inherited?.providerId),
            ),
            initialValue: providerId,
            isExpanded: true,
            items: [
              defaultMenuItem(),
              ...providerIds.map((p) => DropdownMenuItem<String?>(value: p, child: Text(p))),
            ],
            onChanged: (value) {
              final keepsModel =
                  models.any((m) => m.providerId == value && m.modelId == choice.modelId);
              onChanged((providerId: value, modelId: keepsModel ? choice.modelId : null));
            },
          ),
        ),
        const SizedBox(height: 12),
        ResettableField(
          isDefault: choice.modelId == null,
          onReset: () => onChanged((providerId: providerId, modelId: null)),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Model",
              border: const OutlineInputBorder(),
              helperText: _helper(choice.modelId, labelFor(models, inherited?.modelId)),
            ),
            initialValue: modelId,
            isExpanded: true,
            items: [
              defaultMenuItem(),
              ...forProvider.map((m) {
                return DropdownMenuItem<String?>(value: m.modelId, child: Text(_label(m)));
              }),
            ],
            // Pinning a model pins the provider it came from with it.
            onChanged: (value) => onChanged(
              value == null
                  ? (providerId: providerId, modelId: null)
                  : (providerId: listed, modelId: value),
            ),
          ),
        ),
      ],
    );
  }

  String? _helper(String? current, String? inheritedValue) =>
      current != null ? null : "Using ${inheritedValue ?? "the backend default"}";

  static ModelOption? optionFor(List<ModelOption> models, String? modelId) =>
      modelId == null ? null : models.firstWhereOrNull((m) => m.modelId == modelId);

  /// The display name of [modelId], or the id itself if it is unknown.
  static String? labelFor(List<ModelOption> models, String? modelId) {
    final option = optionFor(models, modelId);
    return option == null ? modelId : _label(option);
  }
}
