import "package:flutter/widgets.dart";

import "../../app/voice_controller.dart" show VoiceController, VoiceViewState;
import "../../domain/corner_radius.dart";
import "../../domain/reaction.dart";
import "../../domain/theme_colour.dart";
import "../app_chrome.dart";
import "../theme.dart";

/// The native shell's app: every page is the platform's, so nothing of
/// Flutter's chrome is drawn, and the look is Apple's own.
class ShellAppChrome extends AppChrome {
  const ShellAppChrome();

  @override
  TransitionBuilder? get builder => null;

  @override
  bool get drawersArePages => false;

  /// A message's reactions are the native conversation's own popover.
  @override
  Future<Reaction?>? pickReaction(BuildContext context, List<String> chosen) =>
      null;

  /// Never a page under the shell: voice mode opens through
  /// `NativeSurfaces.openVoice` as a `ShellVoiceSession`, with no route behind it.
  @override
  Widget? voice({
    required VoiceViewState voice,
    required VoiceController controller,
    required VoidCallback onDone,
  }) => null;
}

/// Apple's look, whatever was picked: the defaults, which are the iOS /
/// macOS theme. What was picked is left where it was, for the Flutter
/// frontend. `appLookOverrideProvider` under this shell.
final AppLook shellLook = (
  primary: ThemeColour.apple.seed,
  secondary: ThemeColour.apple.seed,
  radius: CornerRadius.medium.radius,
);
