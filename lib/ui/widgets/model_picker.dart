import "package:collection/collection.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "resettable_field.dart";

/// The provider + model pair, as stored. Picking a model stores the provider
/// that offers it: the registry keys clients by provider id, so the two are
/// only ever sent as a matched pair.
typedef ModelChoice = ({String? providerId, String? modelId});

/// One model out of every configured provider, or `Default`: inherit whatever
/// the level above decides. Used by both the app-level settings and the
/// per-chat override; [inherited] is what `Default` currently resolves to,
/// named under the field so it is never a mystery.
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
          helperText: choice.modelId == null
              ? "Using ${_labelFor(models, inherited?.modelId) ?? "the backend default"}"
              : null,
        ),
      ));
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

/// Every configured model in one list, sorted by label, led by the entry that
/// stores null.
Widget _dropdown({
  required List<ModelOption> models,
  required ModelChoice choice,
  required ValueChanged<ModelChoice> onChanged,
  required String nullLabel,
  required String? helperText,
}) {
  final sorted = _byLabel(models);
  return DropdownButtonFormField<ModelOption?>(
    initialValue: _selected(sorted, choice),
    isExpanded: true,
    decoration: InputDecoration(
      border: const OutlineInputBorder(),
      helperText: helperText,
    ),
    items: [
      DropdownMenuItem<ModelOption?>(value: null, child: Text(nullLabel)),
      for (final m in sorted)
        DropdownMenuItem<ModelOption?>(value: m, child: Text(_label(m))),
    ],
    onChanged: (m) => onChanged((providerId: m?.providerId, modelId: m?.modelId)),
  );
}

/// Matched against the list rather than rebuilt, so a stored pair the backend
/// no longer offers reads as the null entry instead of tripping the dropdown's
/// "exactly one item" assert. A model stored without its provider still names
/// one: whoever offers it.
ModelOption? _selected(List<ModelOption> models, ModelChoice choice) =>
    choice.modelId == null
        ? null
        : models.firstWhereOrNull((m) =>
            m.modelId == choice.modelId &&
            (choice.providerId == null || m.providerId == choice.providerId));

/// The configured models, once they are known. Every picker here needs the
/// same answers to "not yet", "that failed" and "there are none".
class _Models extends ConsumerWidget {
  const _Models(this.builder);

  final Widget Function(List<ModelOption> models) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(availableModelsProvider).when(
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

/// What a model is called in a list, and the order they are listed in. Every
/// field here shows the same models, so they cannot disagree on either.
String _label(ModelOption m) => m.label ?? m.modelId;

List<ModelOption> _byLabel(Iterable<ModelOption> models) => [...models]
  ..sort((a, b) => _label(a).toLowerCase().compareTo(_label(b).toLowerCase()));

/// The display name of [modelId], or the id itself if it is unknown.
String? _labelFor(List<ModelOption> models, String? modelId) {
  if (modelId == null) return null;
  final option = models.firstWhereOrNull((m) => m.modelId == modelId);
  return option == null ? modelId : _label(option);
}
