import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/availability.dart";
import "../domain/builtin_project.dart";
import "../domain/project.dart";
import "../providers.dart";
import "app_command.dart";
import "../app/chat_controller.dart";
import "chat/chat_settings_page.dart";
import "chat/plan_page.dart";
import "chat_actions.dart";
import "marketplace/marketplace_page.dart";
import "profile/profile_page.dart";
import "project_actions.dart";
import "selection.dart";
import "settings/settings_category.dart";
import "voice/voice_page.dart";
import "sidebar/project_palette.dart";

/// Where a frontend takes the app for each [Destination]. Each frontend has
/// its own, an exhaustive switch with no default.
typedef Navigate = Future<void> Function(Commands commands, Destination to);

/// What each [AppItem] does, and whether it can now: one snapshot of the app
/// taken from [context], which is the chat pane's — below the Navigator, so
/// every page an item opens goes over it. An [AppAction] is run here, the
/// frontend asking first for what it needs; a [Destination] goes to the
/// frontend's [Navigate].
///
/// [Commands.watch] is for a build, so a menu greys and labels its items
/// afresh as the app changes; [Commands.read] for a key or a click, which
/// runs a command against the app as it is at that moment.
class Commands {
  Commands._(
    this.context,
    this.ref,
    this._navigate, {
    required this.front,
    required this.project,
    required this.chatId,
    required this.pinned,
    required this.running,
    required this.sidebarShown,
  });

  factory Commands.watch(
    BuildContext context,
    WidgetRef ref, [
    Navigate navigate = flutterNavigate,
  ]) => Commands._of(context, ref, navigate, ref.watch);

  factory Commands.read(
    BuildContext context,
    WidgetRef ref, [
    Navigate navigate = flutterNavigate,
  ]) => Commands._of(context, ref, navigate, ref.read);

  factory Commands._of(
    BuildContext context,
    WidgetRef ref,
    Navigate navigate,
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
      navigate,
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
  final Navigate _navigate;

  /// Whether the chat pane is the page on top.
  final bool front;
  final ProjectRef project;

  /// The open chat, where it is one of this device's and has been read.
  final String? chatId;
  final bool pinned;
  final bool running;
  final bool sidebarShown;

  AppFacts get facts => (
    front: front,
    chatOpen: chatId != null,
    pinned: pinned,
    running: running,
    sidebarShown: sidebarShown,
    hasWorkspace: projectHasWorkspace(project),
    hasMemories: projectHasMemories(project),
    hasSettings: projectHasSettings(project),
  );

  /// Whether [item] can run now, and why not where it cannot.
  Availability availability(AppItem item) => availabilityOf(item, facts);

  /// [item]'s title, saying which way a toggle goes.
  String label(AppItem item) => titleOf(item, facts);

  /// Run [item] if it can be; what stopped it where it cannot.
  Availability run(AppItem item) {
    final availability = this.availability(item);
    if (availability.isAvailable) {
      unawaited(switch (item) {
        final AppAction action => _act(action),
        final Destination to => _navigate(this, to),
      });
    }
    return availability;
  }

  /// Exhaustive: a new action does not compile until it runs here.
  Future<void> _act(AppAction action) async {
    final chatId = this.chatId;
    switch (action) {
      case AppAction.newChat:
        openNewChatIn(context, ref, null);
      case AppAction.newAnonymousChat:
        openNewChatIn(context, ref, const AnonymousProject().dir);
      case AppAction.newOmadaChat:
        openNewChatIn(context, ref, omadaBaseProject);
      case AppAction.pinChat ||
          AppAction.renameChat ||
          AppAction.moveChat ||
          AppAction.deleteChat:
        // Read as it is now: what the menu was drawn from is two facts of it.
        final chat = ref.read(chatControllerProvider(chatId!)).chat!.state;
        await runOnChat(context, ref, chat, action);
      case AppAction.stopTurn:
        await ref.read(chatControllerProvider(chatId!).notifier).abort();
    }
  }

  /// Settings, at [category] — in place of a Settings already on top rather
  /// than a second one over it.
  void settings(SettingsCategory? category) {
    Navigator.of(
      context,
    ).popUntil((route) => route.settings.name != settingsRoute);
    unawaited(openSettings(context, category: category));
  }
}

/// The Flutter frontend's way to every [Destination].
Future<void> flutterNavigate(Commands c, Destination to) async {
  final context = c.context;
  final ref = c.ref;
  final chatId = c.chatId;
  switch (to) {
    case Destination.about:
      c.settings(SettingsCategory.about);
    case Destination.settings:
      c.settings(null);
    case Destination.backUp:
      c.settings(SettingsCategory.data);
    case Destination.welcome:
      c.settings(SettingsCategory.welcome);
    case Destination.keyboardShortcuts:
      c.settings(SettingsCategory.shortcuts);
    case Destination.profile:
      openProfile(context);
    case Destination.marketplace:
      openMarketplace(context);
    case Destination.switchProject:
      await showProjectPalette(context, ref);
    case Destination.toggleSidebar:
      ref.read(sidebarShownProvider.notifier).toggle();
    case Destination.chatSettings:
      openChatSettings(context, chatId!);
    case Destination.showPlan:
      openPlan(context, chatId!);
    // Into the open chat, or a new one where none is open — the new-chat
    // screen's circle.
    case Destination.voiceMode:
      await (chatId == null
          ? startVoiceChat(context, ref)
          : openVoice(context, ref, chatId));
    case Destination.projectWorkspace:
      openProjectWorkspace(context, ref, c.project);
    case Destination.projectMemories:
      openProjectMemories(context, c.project);
    case Destination.projectSettings:
      openProjectSettings(context, c.project);
  }
}
