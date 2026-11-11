import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/reaction.dart";
import "../app/voice_controller.dart" show VoiceController, VoiceViewState;
import "app_shell.dart";
import "theme.dart" show AppLook;

/// What the frontend on screen draws of the app outside the chat page, and
/// what it leaves to Flutter: the window's root, the look the pages wear, how
/// a drawer opens, the reaction strip, voice mode. A seam rather than
/// branches, so `lib/ui` outside `lib/ui/shell/` knows nothing of the shell.
/// The chat page's own is `ChatChrome`.
abstract class AppChrome {
  const AppChrome();

  /// The window's root under the welcome tour and first-run setup.
  Widget get root;

  /// Wraps every page, above the Navigator; null wraps nothing.
  TransitionBuilder? get builder;

  /// The look the pages wear whatever the settings pick; null is the
  /// settings'.
  AppLook? get look;

  /// An activity's drawer opens as a page rather than a sheet.
  bool get drawersArePages;

  /// The reaction picked from the strip over [context], or null; null
  /// where Flutter draws the strip itself.
  Future<Reaction?>? pickReaction(BuildContext context, List<String> chosen);

  /// Voice mode's page, where the frontend draws it itself; null is
  /// Flutter's.
  Widget? voice({
    required VoiceViewState voice,
    required VoiceController controller,
    required VoidCallback onDone,
  });
}

/// The Flutter frontend's: everything is Flutter's.
class FlutterAppChrome extends AppChrome {
  const FlutterAppChrome();

  @override
  Widget get root => const AppShell();

  @override
  TransitionBuilder? get builder => null;

  @override
  AppLook? get look => null;

  @override
  bool get drawersArePages => false;

  @override
  Future<Reaction?>? pickReaction(BuildContext context, List<String> chosen) =>
      null;

  @override
  Widget? voice({
    required VoiceViewState voice,
    required VoiceController controller,
    required VoidCallback onDone,
  }) => null;
}

/// Overridden in `main` by a frontend that draws some of the app itself.
final appChromeProvider = Provider<AppChrome>(
  (ref) => const FlutterAppChrome(),
);
