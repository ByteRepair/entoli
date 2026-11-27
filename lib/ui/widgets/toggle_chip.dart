import "package:flutter/material.dart";

/// A chip ticked on and off: a leading mark, then its name. The mark is in
/// the label rather than the chip's avatar slot, which a [ChoiceChip] paints
/// its check over; and the chip's width glides as the check grows, so a
/// `ChipRow` around it re-flows smoothly rather than snapping. The mark is
/// fitted to [markSize], so the label alone sets no chip apart in height.
class ToggleChip extends StatelessWidget {
  /// The leading mark's box, whatever it is — an icon, a letter in a circle
  /// — so every chip is one height and a row of mixed ones lines up.
  static const markSize = 18.0;

  const ToggleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.leading,
  });

  final Widget label;
  final Widget? leading;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) => AnimatedSize(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    child: ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading case final leading?)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox.square(
                dimension: markSize,
                child: FittedBox(child: leading),
              ),
            ),
          label,
        ],
      ),
      selected: selected,
      onSelected: onSelected,
    ),
  );
}
