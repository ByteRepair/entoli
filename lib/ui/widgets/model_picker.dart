import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// One model out of every configured provider, or `Default`: whatever the level
/// above decides. [inherited] is what `Default` resolves to today.
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
  Widget build(BuildContext context) => _Models((models) => ResettableField(
        isDefault: choice.modelId == null,
        onReset: () => onChanged((providerId: null, modelId: null)),
        child: _dropdown(
          models: models,
          choice: choice,
          onChanged: onChanged,
          nullLabel: defaultOptionLabel,
          helperText: choice.modelId == null ? "Using ${_inheritedName(models)}" : null,
        ),
      ));

  String _inheritedName(List<ModelOption> models) {
    final option = _find(models, inherited?.modelId, inherited?.providerId);
    return option != null ? _label(option) : inherited?.modelId ?? "the backend default";
  }
}

/// One model out of all of them, or none at all. Unlike [ModelPicker] there is
/// no level below to inherit this, so null is off rather than `Default` and
/// there is nothing to reset to.
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
  Widget build(BuildContext context) => _Models((models) => _dropdown(
        models: models,
        choice: choice,
        onChanged: onChanged,
        nullLabel: offLabel,
        helperText: helperText,
      ));
}

Widget _dropdown({
  required List<ModelOption> models,
  required ModelChoice choice,
  required ValueChanged<ModelChoice> onChanged,
  required String nullLabel,
  required String? helperText,
}) =>
    DropdownButtonFormField<ModelOption?>(
      initialValue: _find(models, choice.modelId, choice.providerId),
      isExpanded: true,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        helperText: helperText,
      ),
      items: [
        DropdownMenuItem<ModelOption?>(value: null, child: Text(nullLabel)),
        for (final m in models)
          DropdownMenuItem<ModelOption?>(value: m, child: Text(_label(m))),
      ],
      onChanged: (m) => onChanged((providerId: m?.providerId, modelId: m?.modelId)),
    );

/// A stored pair is matched against the list rather than trusted: one the
/// backend no longer offers has to read as the null entry, or the dropdown
/// asserts on having no item for its value. A pair missing its provider still
/// names one — whoever offers the model.
ModelOption? _find(List<ModelOption> models, String? modelId, [String? providerId]) =>
    modelId == null
        ? null
        : models.firstWhereOrNull((m) =>
            m.modelId == modelId && (providerId == null || m.providerId == providerId));

/// The configured models in the order every field lists them, once they are
/// known. Every picker here needs the same answers to "not yet", "that failed"
/// and "there are none".
class _Models extends ConsumerWidget {
  const _Models(this.builder);

  final Widget Function(List<ModelOption> models) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(sortedModelsProvider).when(
            data: (models) =>
                models.isEmpty ? const Text("No models available.") : builder(models),
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

/// Every field shows the same models, so they cannot disagree on what one is
/// called.
String _label(ModelOption m) => m.label ?? m.modelId;
