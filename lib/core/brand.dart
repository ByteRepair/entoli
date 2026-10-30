import "package:flutter/foundation.dart" show kDebugMode;

/// The app's name as a user sees it — the launcher, the window title, the bar
/// over the empty pane and the keyring's item labels all read it. The debug
/// build names itself so the two installs are told apart anywhere both are
/// seen.
const appBrand = kDebugMode ? "Entoli (Debug)" : "Entoli";
