import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/availability.dart";
import "../domain/builtin_project.dart";
import "../domain/project.dart";
import "../providers.dart";
import "app_command.dart";
import "chat/chat_controller.dart";
import "chat/chat_settings_page.dart";
import "chat/plan_page.dart";
import "chat_actions.dart";
import "marketplace/marketplace_page.dart";
import "profile/profile_page.dart";
import "project_actions.dart";
import "selection.dart";
import "settings/settings_category.dart";
import "voice/voice_page.dart";
import "shell/shell_palette.dart";
import "sidebar/project_palette.dart";
import "widgets/liquid_glass.dart";

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
    required this.chatId,
    required this.pinned,
    required this.running,
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
    // The two facts a menu draws, not the whole state, which changes with
    // every message that lands.
    final open = id == null || get(isMirroredChatProvider(id))
        ? null
        : get(
            chatControllerProvider(id).select(
              (s) => s.chat == null
                  ? null
                  : (pinned: s.chat!.state.pinned, running: s.isRunning),
            ),
          );
    return Commands._(
      context,
      ref,
      front: ModalRoute.isCurrentOf(context) ?? true,
      project: get(selectedProjectProvider),
      chatId: open == null ? null : id,
      pinned: open?.pinned ?? false,
      running: open?.running ?? false,
      sidebarShown: get(sidebarShownProvider),
    );
  }

  final BuildContext context;
  final WidgetRef ref;

  /// Whether the chat pane is the page on top.
  final bool front;
  final ProjectRef project;

  /// The open chat, where it is one of this device's and has been read.
  final String? chatId;
  final bool pinned;
  final bool running;
  final bool sidebarShown;

  /// Whether [command] can run now, and why not where it cannot: the one
  /// answer the keys, the menus and Shortcuts all ask.
  Availability availability(AppCommand command) {
    if (!command.anywhere && !front) {
      return const Unavailable("A page is open over the chat.");
    }
    Availability needs(bool ok, String why) =>
        ok ? const Available() : Unavailable(why);
    return switch (command) {
      AppCommand.pinChat ||
      AppCommand.renameChat ||
      AppCommand.moveChat ||
      AppCommand.deleteChat ||
      AppCommand.chatSettings ||
      // The page says where a chat has none.
      AppCommand.showPlan => needs(chatId != null, "No chat is open."),
      AppCommand.stopTurn => needs(running, "No turn is running."),
      AppCommand.projectWorkspace => needs(
        projectHasWorkspace(project),
        "This project has no workspace.",
      ),
      AppCommand.projectMemories => needs(
        projectHasMemories(project),
        "This project keeps no memories.",
      ),
      AppCommand.projectSettings => needs(
        projectHasSettings(project),
        "This project has no settings.",
      ),
      _ => const Available(),
    };
  }

  /// [command]'s label, saying which way a toggle goes.
  String label(AppCommand command) => switch (command) {
    AppCommand.pinChat when pinned => "Unpin Chat",
    AppCommand.toggleSidebar => sidebarShown ? "Hide Sidebar" : "Show Sidebar",
    _ => command.label,
  };

  /// Run [command] if it can be; what stopped it where it cannot.
  Availability run(AppCommand command) {
    final availability = this.availability(command);
    if (availability.isAvailable) unawaited(_run(command));
    return availability;
  }

  Future<void> _run(AppCommand command) async {
    final chatId = this.chatId;
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
      // Under the native shell, the shell's own palette.
      case AppCommand.switchProject:
        if (ref.read(liquidGlassProvider).on) {
          ref.read(shellPaletteProvider.notifier).open();
        } else {
          await showProjectPalette(context, ref);
        }
      case AppCommand.toggleSidebar:
        ref.read(sidebarShownProvider.notifier).toggle();
      case AppCommand.pinChat ||
          AppCommand.renameChat ||
          AppCommand.moveChat ||
          AppCommand.deleteChat:
        // Read as it is now: what the menu was drawn from is two facts of it.
        final chat = ref.read(chatControllerProvider(chatId!)).chat!.state;
        await runOnChat(context, ref, chat, command);
      case AppCommand.chatSettings:
        openChatSettings(context, chatId!);
      case AppCommand.showPlan:
        openPlan(context, chatId!);
      // Into the open chat, or a new one where none is open — the new-chat
      // screen's circle.
      case AppCommand.voiceMode:
        await (chatId == null
            ? startVoiceChat(context, ref)
            : openVoice(context, ref, chatId));
      case AppCommand.stopTurn:
        await ref.read(chatControllerProvider(chatId!).notifier).abort();
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
}
