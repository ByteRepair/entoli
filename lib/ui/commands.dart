import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/builtin_project.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "app_command.dart";
import "chat/chat_controller.dart";
import "chat/chat_settings_page.dart";
import "chat/plan_page.dart";
import "chat/widgets/plan_view.dart";
import "chat_actions.dart";
import "marketplace/marketplace_page.dart";
import "profile/profile_page.dart";
import "project_actions.dart";
import "selection.dart";
import "settings/settings_category.dart";
import "sidebar/project_palette.dart";

/// What each [AppCommand] does, and whether it can now: one snapshot of the
/// app taken from [context], which is the chat pane's — below the Navigator,
/// so every page a command opens goes over it.
///
/// [Commands.watch] is for a build, so a menu greys and labels its items
/// afresh as the app changes; [Commands.read] for a key or a click, which
/// runs a command against the app as it is at that moment.
class Commands {
  Commands._(
    this.context,
    this.ref, {
    required this.front,
    required this.project,
    required this.chat,
    required this.running,
    required this.hasPlan,
    required this.sidebarShown,
  });

  factory Commands.watch(BuildContext context, WidgetRef ref) =>
      Commands._of(context, ref, ref.watch);

  factory Commands.read(BuildContext context, WidgetRef ref) =>
      Commands._of(context, ref, ref.read);

  factory Commands._of(
    BuildContext context,
    WidgetRef ref,
    T Function<T>(ProviderListenable<T>) get,
  ) {
    final id = get(selectedChatIdProvider);
    // A mirror's state is its home device's, and so is everything done to it.
    final local = id != null && !get(isMirroredChatProvider(id));
    return Commands._(
      context,
      ref,
      front: ModalRoute.isCurrentOf(context) ?? true,
      project: get(selectedProjectProvider),
      chat: local
          ? get(chatControllerProvider(id).select((s) => s.chat?.state))
          : null,
      running:
          local && get(chatControllerProvider(id).select((s) => s.isRunning)),
      hasPlan:
          local && get(planProvider(id).select((plan) => plan.value != null)),
      sidebarShown: get(sidebarShownProvider),
    );
  }

  final BuildContext context;
  final WidgetRef ref;

  /// Whether the chat pane is the page on top.
  final bool front;
  final ProjectRef project;

  /// The open chat, where it is one of this device's.
  final ChatState? chat;
  final bool running;
  final bool hasPlan;
  final bool sidebarShown;

  bool canRun(AppCommand command) {
    if (!command.anywhere && !front) return false;
    return switch (command) {
      AppCommand.pinChat ||
      AppCommand.renameChat ||
      AppCommand.moveChat ||
      AppCommand.deleteChat ||
      AppCommand.chatSettings => chat != null,
      AppCommand.showPlan => hasPlan,
      AppCommand.stopTurn => running,
      AppCommand.projectWorkspace => projectHasWorkspace(project),
      AppCommand.projectMemories => projectHasMemories(project),
      AppCommand.projectSettings => projectHasSettings(project),
      _ => true,
    };
  }

  /// [command]'s label, saying which way a toggle goes.
  String label(AppCommand command) => switch (command) {
    AppCommand.pinChat when chat?.pinned ?? false => "Unpin Chat",
    AppCommand.toggleSidebar => sidebarShown ? "Hide Sidebar" : "Show Sidebar",
    _ => command.label,
  };

  /// Run [command] if it can be, false where it cannot.
  bool run(AppCommand command) {
    if (!canRun(command)) return false;
    unawaited(_run(command));
    return true;
  }

  Future<void> _run(AppCommand command) async {
    final chat = this.chat;
    switch (command) {
      case AppCommand.about:
        _settings(SettingsCategory.about);
      case AppCommand.settings:
        _settings(null);
      case AppCommand.backUp:
        _settings(SettingsCategory.data);
      case AppCommand.welcome:
        _settings(SettingsCategory.welcome);
      case AppCommand.keyboardShortcuts:
        _settings(SettingsCategory.shortcuts);
      case AppCommand.profile:
        openProfile(context);
      case AppCommand.marketplace:
        openMarketplace(context);
      case AppCommand.newChat:
        openNewChatIn(context, ref, null);
      case AppCommand.newAnonymousChat:
        openNewChatIn(context, ref, const AnonymousProject().dir);
      case AppCommand.newOmadaChat:
        openNewChatIn(context, ref, omadaBaseProject);
      case AppCommand.switchProject:
        await showProjectPalette(context, ref);
      case AppCommand.toggleSidebar:
        ref.read(sidebarShownProvider.notifier).toggle();
      case AppCommand.pinChat:
        await setChatPinned(ref, chat!, !chat.pinned, open: true);
      case AppCommand.renameChat:
        await renameChat(context, ref, chat!, open: true);
      case AppCommand.moveChat:
        await moveChat(context, ref, chat!);
      case AppCommand.deleteChat:
        await deleteChat(context, ref, chat!, open: true);
      case AppCommand.chatSettings:
        _push(ChatSettingsPage(chatId: chat!.id));
      case AppCommand.showPlan:
        _push(PlanPage(chatId: chat!.id));
      case AppCommand.stopTurn:
        await ref.read(chatControllerProvider(chat!.id).notifier).abort();
      case AppCommand.projectWorkspace:
        openProjectWorkspace(context, ref, project);
      case AppCommand.projectMemories:
        openProjectMemories(context, project);
      case AppCommand.projectSettings:
        openProjectSettings(context, project);
    }
  }

  /// Settings, at [category] — in place of a Settings already on top rather
  /// than a second one over it.
  void _settings(SettingsCategory? category) {
    Navigator.of(
      context,
    ).popUntil((route) => route.settings.name != settingsRoute);
    unawaited(openSettings(context, category: category));
  }

  void _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}
