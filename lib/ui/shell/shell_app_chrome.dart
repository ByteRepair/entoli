import "package:flutter/widgets.dart";

import "../../app/voice_controller.dart" show VoiceController, VoiceViewState;
import "../../domain/reaction.dart";
import "../../domain/corner_radius.dart";
import "../../domain/theme_colour.dart";
import "../app_chrome.dart";
import "../theme.dart";
import "shell_popup.dart";
import "shell_voice.dart";
import "shell_window.dart" show ShellInsets;

/// The native shell's app: the window is SwiftUI's, the Flutter view inside
/// it padded by the shell's bars, and the pages in Apple's own look.
class ShellAppChrome extends AppChrome {
  const ShellAppChrome();

  @override
  TransitionBuilder? get builder =>
      (context, child) => ShellInsets(child: child!);

  /// The composer is the shell's, over the Flutter view a sheet is drawn in;
  /// a page is what it steps aside for, its bar then the window's.
  @override
  bool get drawersArePages => true;

  @override
  Future<Reaction?>? pickReaction(BuildContext context, List<String> chosen) {
    final anchor = anchorOf(context);
    if (anchor == null) return null;
    return showShellStrip(
      anchor: anchor,
      choices: [
        for (final r in Reaction.values) (glyph: r.emoji, name: r.name),
      ],
      chosen: {
        for (final (i, r) in Reaction.values.indexed)
          if (chosen.contains(r.emoji)) i,
      },
    ).then((at) => at == null ? null : Reaction.values.elementAtOrNull(at));
  }

  /// Voice mode over the whole window, drawn by the shell; the route stays,
  /// so leaving is still popping it and the session still lives as long as
  /// the page.
  @override
  Widget? voice({
    required VoiceViewState voice,
    required VoiceController controller,
    required VoidCallback onDone,
  }) => ShellVoice(voice: voice, controller: controller, onDone: onDone);
}

/// Apple's look, whatever was picked: the defaults, which are the iOS /
/// macOS theme. What was picked is left where it was, for the Flutter
/// frontend. `appLookOverrideProvider` under this shell.
final AppLook shellLook = (
  primary: ThemeColour.apple.seed,
  secondary: ThemeColour.apple.seed,
  radius: CornerRadius.medium.radius,
);
