import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../providers.dart";
import "settings/welcome_page.dart";

/// Shows the welcome tour instead of the app until it is finished. The tour is
/// the home content, not a route over it, so the back key cannot skip it and
/// the shell is never underneath. In the home chain rather than the shell for
/// the reason the `Incoming*` wrappers are: an incoming share or a trigger tap
/// on first launch should stay above the tour.
class WelcomeGate extends ConsumerWidget {
  const WelcomeGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seen =
        ref.watch(appSettingsProvider.select((s) => s.licenceAccepted));
    return seen ? child : const WelcomePage();
  }
}