import "package:flutter/material.dart";

import "../../domain/models.dart";
import "resettable_field.dart";

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
      return const Text("No models available. Start a chat to load models.");
    }

    final providerIds = models.map((m) => m.providerId).toSet().toList()..sort();
    // On Default, list the models of the provider that will actually be used.
    // With nothing to inherit there is no such provider, and guessing one
    // would make Default mean something that shifts as providers come and go.
    final listed = choice.providerId ?? inherited?.providerId;
    final forProvider = models.where((m) => m.providerId == listed).toList()
      ..sort((a, b) => _label(a).toLowerCase().compareTo(_label(b).toLowerCase()));

    final modelId = forProvider.any((m) => m.modelId == choice.modelId) ? choice.modelId : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ResettableField(
          isDefault: choice.providerId == null,
          onReset: () => onChanged((providerId: null, modelId: null)),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Provider",
              border: const OutlineInputBorder(),
              helperText: _helper(choice.providerId, inherited?.providerId),
            ),
            initialValue: choice.providerId,
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
          onReset: () => onChanged((providerId: choice.providerId, modelId: null)),
          child: DropdownButtonFormField<String?>(
            decoration: InputDecoration(
              labelText: "Model",
              border: const OutlineInputBorder(),
              helperText: _helper(choice.modelId, labelFor(models, inherited?.modelId)),
            ),
            initialValue: modelId,
            items: [
              defaultMenuItem(),
              ...forProvider.map((m) {
                return DropdownMenuItem<String?>(value: m.modelId, child: Text(_label(m)));
              }),
            ],
            // Pinning a model pins the provider it came from with it.
            onChanged: (value) => onChanged(
              value == null
                  ? (providerId: choice.providerId, modelId: null)
                  : (providerId: listed, modelId: value),
            ),
          ),
        ),
      ],
    );
  }

  static String _label(ModelOption m) => m.label ?? m.modelId;

  String? _helper(String? current, String? inheritedValue) =>
      current != null ? null : "Using ${inheritedValue ?? "the backend default"}";

  /// The display name of [modelId], or the id itself if it is unknown.
  static String? labelFor(List<ModelOption> models, String? modelId) {
    if (modelId == null) return null;
    final match = models.where((m) => m.modelId == modelId);
    return match.isEmpty ? modelId : _label(match.first);
  }
}
