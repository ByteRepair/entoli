import "package:flutter/foundation.dart";

// The target rather than `Platform`, so a widget test can name its platform.

/// Android or iOS, outside a browser.
bool get isPhone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Android, outside a browser.
bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// macOS, outside a browser.
bool get isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
