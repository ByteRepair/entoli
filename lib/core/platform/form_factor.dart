import "package:flutter/foundation.dart";

// The target rather than `Platform`, so a widget test can name its platform.

/// Android or iOS.
bool get isPhone =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Linux, macOS or Windows.
bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

bool get isMac => defaultTargetPlatform == TargetPlatform.macOS;
