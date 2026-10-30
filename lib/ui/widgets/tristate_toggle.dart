import "package:flutter/material.dart";

import "../../domain/tristate.dart";

/// Off | Inherit | On, the picked one filled with the primary colour.
class TristateToggle extends StatelessWidget {
  const TristateToggle({super.key, required this.value, this.onChanged});

  final Tristate value;
  final ValueChanged<Tristate>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SegmentedButton<Tristate>(
      segments: [
        for (final v in Tristate.values)
          ButtonSegment(value: v, label: Text(v.label)),
      ],
      selected: {value},
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primary,
        selectedForegroundColor: scheme.onPrimary,
      ),
      onSelectionChanged: onChanged == null
          ? null
          : (picked) => onChanged!(picked.first),
    );
  }
}
