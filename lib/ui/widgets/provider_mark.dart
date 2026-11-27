import "package:flutter/material.dart";

/// The hue a provider's mark wears, 0 to 359, from its name's characters
/// rather than `hashCode`, which is not the same from one run to the next.
int providerHue(String name) =>
    name.codeUnits.fold(0, (a, c) => a * 31 + c) % 360;

/// A provider's initial on a colour of its own, so a list reads by provider
/// at a glance and two names sharing a letter are still told apart. Not its
/// logo, which the companies' trademark terms keep to what they approve.
class ProviderMark extends StatelessWidget {
  const ProviderMark(this.name, {super.key, this.radius = 18});

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hue = providerHue(name).toDouble();
    final bg = HSLColor.fromAHSL(1, hue, 0.45, dark ? 0.28 : 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.5, dark ? 0.86 : 0.28).toColor();
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: Text(
        name.isEmpty ? "?" : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }
}
