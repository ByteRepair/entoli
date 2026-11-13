import "package:flutter_riverpod/misc.dart" show Override;

import "../app_chrome.dart" show appChromeProvider;
import "../chat/chat_chrome.dart" show drawsOpenChatProvider;
import "../theme.dart" show appLookOverrideProvider;
import "shell_app_chrome.dart";

/// The seams the SwiftUI frontend binds over Flutter's.
final List<Override> shellOverrides = [
  drawsOpenChatProvider.overrideWithValue(true),
  appChromeProvider.overrideWithValue(const ShellAppChrome()),
  appLookOverrideProvider.overrideWithValue(shellLook),
];
