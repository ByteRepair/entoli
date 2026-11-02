/// The native shell's channel: a SwiftUI window around the one Flutter view,
/// on iOS and macOS with Liquid Glass on. What travels over it is the app's
/// own, in `lib/ui/shell/`; this package is the Swift that answers it.
library;

import "package:flutter/services.dart";

/// Both ways: `start` and `snapshot` to Swift, `insets` and `intent` back.
/// See "Liquid Glass" in `lib/ui/AGENTS.md`.
const shellChannel = MethodChannel("entoli_glass/shell");
