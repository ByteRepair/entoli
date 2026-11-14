import "package:entoli_glass/entoli_glass.dart" show NativeSettings;
import "package:flutter_riverpod/misc.dart" show Override;

import "../../domain/sign_in_page.dart";
import "../../providers.dart" show signInPagesProvider;

import "../app_chrome.dart" show appChromeProvider;
import "../chat/chat_chrome.dart" show drawsOpenChatProvider;
import "../theme.dart" show appLookOverrideProvider;
import "shell_app_chrome.dart";

/// The seams the SwiftUI frontend binds over Flutter's.
final List<Override> shellOverrides = [
  drawsOpenChatProvider.overrideWithValue(true),
  appChromeProvider.overrideWithValue(const ShellAppChrome()),
  appLookOverrideProvider.overrideWithValue(shellLook),
  signInPagesProvider.overrideWithValue(_ShellSignInPages()),
];

/// The page the client presented, which it is asked to take down.
class _ShellSignInPages implements SignInPages {
  final _native = NativeSettings();

  @override
  Future<void> close() => _native.closeSignInPage();
}
