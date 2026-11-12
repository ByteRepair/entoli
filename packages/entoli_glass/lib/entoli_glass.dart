/// The native shell: a SwiftUI window around the one Flutter view, on iOS and
/// macOS with Liquid Glass on. Its protocol is `pigeons/shell.dart` at the
/// app's root, generated into both ends: [NativeShell] is what the app tells
/// the client to draw, and each `*Intents` class what the client says the user
/// did. The app's use of it is `lib/ui/shell/`; this package is the Swift that
/// answers it. See "Liquid Glass" in `lib/ui/AGENTS.md`.
library;

export "src/shell_contract.g.dart";
export "src/settings_contract.g.dart" hide wrapResponse;
