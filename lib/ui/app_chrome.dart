import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/reaction.dart";
import "../app/voice_controller.dart" show VoiceController, VoiceViewState;

/// What the frontend on screen draws of the app outside the chat page, and
/// what it leaves to Flutter: how a drawer opens, the reaction strip, voice
/// mode. The look the pages wear is `appLookOverrideProvider`'s. The window's root is `main`'s to pick,
/// being the one place that knows both frontends. A seam rather than
/// branches, so `lib/ui` outside `lib/ui/shell/` knows nothing of the shell.
/// The chat page's own is `ChatChrome`.
abstract class AppChrome {
  const AppChrome();

  /// Wraps every page, above the Navigator; null wraps nothing.
  TransitionBuilder? get builder;

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
  TransitionBuilder? get builder => null;

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
