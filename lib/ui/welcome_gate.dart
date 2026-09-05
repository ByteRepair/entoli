import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../providers.dart";
import "settings/welcome_page.dart";

/// Wraps the app so a first run is met with the welcome tour over whatever is
/// on screen, in the shape the `Incoming*` wrappers have. In the home chain
/// rather than the shell for the reason they are: an incoming share or a
/// reminder tap on first launch should stay above the tour, and what this
/// pushes over is decided by where it sits, not by what the shell knows.
class WelcomeGate extends ConsumerStatefulWidget {
  const WelcomeGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WelcomeGate> createState() => _WelcomeGateState();
}

class _WelcomeGateState extends ConsumerState<WelcomeGate> {
  @override
  void initState() {
    super.initState();
    // On the first frame rather than in initState: pushing needs a Navigator,
    // which does not exist until there is somewhere to put one.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
  }

  void _maybeWelcome() {
    if (!mounted || ref.read(appSettingsProvider).welcomeSeen) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WelcomePage()));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}