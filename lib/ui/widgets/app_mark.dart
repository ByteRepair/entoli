import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_svg/flutter_svg.dart";

import "../../domain/app_icon.dart";
import "../../providers.dart";

/// One of the app's icons, drawn from the same SVG the launcher icon is
/// generated from. Takes the icon rather than reading it, so the settings page
/// can offer the one that is not currently chosen.
class AppIconImage extends StatelessWidget {
  const AppIconImage(this.icon, {super.key, this.size = 32});

  final AppIcon icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(icon.asset, width: size, height: size);
  }
}

/// The icon the app is currently wearing.
class AppMark extends ConsumerWidget {
  const AppMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = ref.watch(appSettingsProvider.select((s) => s.appIcon));
    return AppIconImage(icon, size: size);
  }
}
