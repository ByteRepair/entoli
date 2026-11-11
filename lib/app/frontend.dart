import "package:flutter/foundation.dart" show TargetPlatform;

import "../domain/app_settings.dart";

/// What draws the app. Flutter's runs everywhere; SwiftUI's is the Apple
/// devices' own, around Flutter's conversation and pages.
enum Frontend { flutter, swiftUI }

/// Chosen once, at launch, before the first frame: switching asks for a
/// relaunch, the window being the frontend's from then on.
Frontend chooseFrontend(AppSettings settings, TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS when settings.liquidGlass => Frontend.swiftUI,
      _ => Frontend.flutter,
    };
