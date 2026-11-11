import "package:entoli_glass/entoli_glass.dart" show ChatBarSnapshot;
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/chat_controller.dart" show TurnDriver;
import "../../app/composer.dart";
import "../../domain/room/room_state.dart" show ChatViewState;
import "../../app/plan.dart";
import "../../domain/models.dart";
import "../../domain/plan.dart" show sectionsProgress;
import "../../domain/project.dart";
import "../chat/chat_chrome.dart";
import "../chat/chat_settings_page.dart" show openChatSettings;
import "../chat/plan_page.dart" show openPlan;
import "../chat/widgets/browser_strip.dart" show BrowserPrompts;
import "../chat/widgets/composer_controller.dart";
import "shell_composer.dart";
import "shell_new_chat.dart";
import "shell_turn.dart";

/// The native shell's chat page: its bar and composer are the window's,
/// over the page; its turn surface draws the question too; the new-chat
/// screen is native. What stays Flutter's is the conversation, and the
/// browser's prompts, which are fields and a picker.
class ShellChatChrome extends ChatChrome {
  const ShellChatChrome();

  @override
  bool get overPage => true;

  @override
  bool get commandHint => false;

  @override
  Widget composer({
    Key? key,
    required ComposerController controller,
    required ComposerModel model,
    required ComposerBinding binding,
  }) => ShellComposer(
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
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ShellTurnSurface(view: view, notifier: driver, onWithdrawn: onWithdrawn),
      if (view.chat case final chat?) BrowserPrompts(chatId: chat.state.id),
    ],
  );

  @override
  Widget questions({required ChatViewState view, required TurnDriver driver}) =>
      const SizedBox.shrink();

  @override
  Widget? chatBar({required ChatState state, required ChatViewState view}) =>
      _ChatBar(state: state, view: view);

  @override
  Widget? newChatBar({
    required ProjectRef at,
    required VoidCallback onSettings,
  }) => ShellChatBar(
    bar: ChatBarSnapshot(
      draft: true,
      project: at.project == null ? null : projectLabel(at.project),
      settings: at.device == null,
    ),
    onSettings: onSettings,
  );

  @override
  Widget? newChat({
    required ProjectRef at,
    required ComposerController controller,
    required bool starting,
  }) => ShellNewChat(at: at, controller: controller, starting: starting);
}

/// A chat's bar: its title, the line under it, the running spinner, the
/// plan and the settings, as the chat's state.
class _ChatBar extends ConsumerWidget {
  const _ChatBar({required this.state, required this.view});

  final ChatState state;
  final ChatViewState view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(planProvider(state.id)).value;
    final progress = plan == null ? null : sectionsProgress(plan);
    return ShellChatBar(
      bar: ChatBarSnapshot(
        title: state.title,
        project: state.project == null ? null : projectLabel(state.project),
        pinned: state.pinned,
        expiresAt: state.tempTtlExpiresAt?.millisecondsSinceEpoch,
        running: view.isRunning,
        planDone: progress?.$1,
        planTotal: progress?.$2,
      ),
      onPlan: () => openPlan(context, state.id),
      onSettings: () => openChatSettings(context, state.id),
    );
  }
}
