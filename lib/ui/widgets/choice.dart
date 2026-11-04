import "package:flutter/material.dart";

/// One of a row of things to pick: a swatch, a corner, an app icon, a Bot
/// Avatar's colour. A [corners] of null is a circle. The ring the selected one
/// wears is here rather than at each row, which is what keeps them the same
/// ring.
class Choice extends StatelessWidget {
  const Choice({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.label,
    this.corners,
    this.fill,
    this.gradient,
    this.width,
    this.height,
    this.padding,
    this.child,
  });

  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  /// What a reader is told, where the choice draws no text of its own.
  final String? label;
  final BorderRadius? corners;
  final Color? fill;

  /// Painted over [fill] where given.
  final Gradient? gradient;
  final double? width;
  final double? height;
  final EdgeInsets? padding;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: corners,
          customBorder: corners == null ? const CircleBorder() : null,
          child: Container(
            width: width,
            height: height,
            padding: padding,
            decoration: BoxDecoration(
              color: fill,
              gradient: gradient,
              shape: corners == null ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: corners,
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
