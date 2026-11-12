import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../../app/composer.dart";
import "../../app/transcript/transcript.dart";
import "../../domain/quote.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../app/chat_controller.dart" show TurnDriver;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "widgets/composer.dart";
import "widgets/composer_controller.dart";
import "widgets/turn_surface.dart";

/// What the frontend on screen draws of the chat page and what it leaves to
/// the page: the composer, the turn surface, the bars, the new-chat screen.
/// A seam rather than branches in the page, so the page knows nothing of
/// which frontend it is in. The Flutter frontend's is [FlutterChatChrome];
/// the native shell's is in `lib/ui/shell/`.
abstract class ChatChrome {
  const ChatChrome();

  /// The frontend's bar and composer lie over the page, which runs under
  /// both: the page has no bar of its own, and what is at its foot floats
  /// above the composer.
  bool get overPage;

  Widget composer({
    Key? key,
    required ComposerController controller,
    required ComposerModel model,
    required ComposerBinding binding,
  });

  Widget turnSurface({
    required ChatViewState view,
    required TurnDriver driver,
    ValueChanged<Draft>? onWithdrawn,
  });

  /// The question the turn waits on, in the composer's place.
  Widget questions({required ChatViewState view, required TurnDriver driver});

  /// A chat's bar where the frontend draws its own, which draws nothing on
  /// the page; null is the page's own bar.
  Widget? chatBar({required ChatState state, required ChatViewState view});

  /// The new-chat screen's bar, as [chatBar] is a chat's.
  Widget? newChatBar({
    required ProjectRef at,
    required VoidCallback onSettings,
  });

  /// The new-chat screen where the frontend draws its own; null is the
  /// page's.
  Widget? newChat({
    required ProjectRef at,
    required ComposerController controller,
    required bool starting,
  });

  /// The conversation where the frontend draws its own from [transcript];
  /// null is the page's list. [driver] is what a message's actions act
  /// through, null for a mirror this device does not hold; [onReply] quotes a
  /// selected passage into the composer.
  Widget? conversation({
    required String chatId,
    required Transcript transcript,
    required ChatViewState view,
    required ProviderListenable<ChatViewState> source,
    required ValueChanged<Quote> onReply,
    TurnDriver? driver,
  }) => null;
}

/// The Flutter frontend's: everything is the page's.
class FlutterChatChrome extends ChatChrome {
  const FlutterChatChrome();

  @override
  bool get overPage => false;

  @override
  Widget composer({
    Key? key,
    required ComposerController controller,
    required ComposerModel model,
    required ComposerBinding binding,
  }) => Composer(
    key: key,
    controller: controller,
    model: model,
    binding: binding,
  );

  @override
  Widget turnSurface({
    required ChatViewState view,
    required TurnDriver driver,
    ValueChanged<Draft>? onWithdrawn,
  }) => TurnSurface(view: view, notifier: driver, onWithdrawn: onWithdrawn);

  @override
  Widget questions({required ChatViewState view, required TurnDriver driver}) =>
      TurnQuestions(view: view, notifier: driver);

  @override
  Widget? chatBar({required ChatState state, required ChatViewState view}) =>
      null;

  @override
  Widget? newChatBar({
    required ProjectRef at,
    required VoidCallback onSettings,
  }) => null;

  @override
  Widget? newChat({
    required ProjectRef at,
    required ComposerController controller,
    required bool starting,
  }) => null;
}

/// Overridden in `main` by a frontend that draws the chat page's chrome
/// itself.
final chatChromeProvider = Provider<ChatChrome>(
  (ref) => const FlutterChatChrome(),
);
