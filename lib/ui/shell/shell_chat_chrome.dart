import "package:flutter/widgets.dart";

import "../../app/chat_controller.dart" show TurnDriver;
import "../../app/composer.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../chat/chat_chrome.dart";
import "../chat/widgets/composer_controller.dart";

/// The native shell's chat page, which draws nothing: the open chat and the
/// new-chat screen are published by `ShellChat` from the app's state, and
/// the window draws them. What stays Flutter's is the pages pushed over it.
class ShellChatChrome extends ChatChrome {
  const ShellChatChrome();

  @override
  bool get overPage => true;

  @override
  bool get drawsOpenChat => true;

  // The page draws none of these under the shell: `ShellChat` publishes the
  // open chat and the new-chat screen from the app's state.

  @override
  Widget composer({
    Key? key,
    required ComposerController controller,
    required ComposerModel model,
    required ComposerBinding binding,
  }) => const SizedBox.shrink();

  @override
  Widget turnSurface({
    required ChatViewState view,
    required TurnDriver driver,
    ValueChanged<Draft>? onWithdrawn,
  }) => const SizedBox.shrink();

  @override
  Widget questions({required ChatViewState view, required TurnDriver driver}) =>
      const SizedBox.shrink();

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
