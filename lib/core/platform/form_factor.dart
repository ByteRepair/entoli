import "package:flutter/foundation.dart";

// The target rather than `Platform`, so a widget test can name its platform.

/// Android or iOS, outside a browser.
bool get isPhone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Linux, macOS or Windows, outside a browser.
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Android, outside a browser.
bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// macOS, outside a browser.
bool get isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
