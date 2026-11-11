import "package:flutter/material.dart";
import "package:flutter_svg/flutter_svg.dart";

/// The app's icon, drawn from the same SVG the launcher icon is made from.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset("assets/icons/cookie.svg", width: size, height: size);
}
