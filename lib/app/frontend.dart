import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/app_settings.dart";

/// What draws the app. Flutter's runs everywhere; SwiftUI's is the Apple
/// devices' own, around Flutter's conversation and pages.
enum Frontend { flutter, swiftUI }

/// Chosen once, at launch, before the first frame: switching asks for a
/// relaunch, the window being the frontend's from then on.
/// [native] is whether the platform has a frontend of its own.
Frontend chooseFrontend(AppSettings settings, {required bool native}) =>
    native && settings.liquidGlass ? Frontend.swiftUI : Frontend.flutter;

/// What this launch draws with, and whether the platform has a frontend of
/// its own to offer — the setting shows only where it does. Settled at
/// launch: a change to the setting waits for a relaunch.
class FrontendChoice {
  const FrontendChoice({this.current = Frontend.flutter, this.native = false});

  final Frontend current;

  /// iOS and macOS, whose SwiftUI frontend the setting picks.
  final bool native;

  bool get swiftUI => current == Frontend.swiftUI;
}

/// Overridden in `main` with the launch's choice.
final frontendProvider = Provider<FrontendChoice>(
  (ref) => const FrontendChoice(),
);
