/// What can be done to one chat from outside it: its sidebar row's menu and
/// the app's Chat menu, which acts on the open one. Each works out for itself
/// whether [ChatState] is the chat on screen — whose controller holds a copy of
/// what is written here — and whether it is a mirror, whose controller is its
/// home device's.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/chat_intents.dart" show ChatEditor;
import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "app_command.dart";
import "../app/chat_controller.dart";
import "selection.dart";
import "widgets/dialogs.dart";

/// The commands that act on one chat, in the order a menu offers them.
const chatCommands = [
  AppAction.pinChat,
  AppAction.renameChat,
  AppAction.moveChat,
  AppAction.deleteChat,
];

/// Run one of [chatCommands] on [chat].
Future<void> runOnChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
  AppAction command,
) => switch (command) {
  AppAction.pinChat => setChatPinned(ref, chat, !chat.pinned),
  AppAction.renameChat => renameChat(context, ref, chat),
  AppAction.moveChat => moveChat(context, ref, chat),
  AppAction.deleteChat => deleteChat(context, ref, chat),
  _ => throw ArgumentError.value(command, "command", "not a chat command"),
};

/// The writes behind the actions below, with no dialog: what the row menu,
/// the Chat menu and Shortcuts share. Each works out for itself whether its
/// chat is the one on screen, whose controller holds a copy of what it
/// writes, and whether it is a mirror, whose controller is its home
/// device's.
class ChatEdits implements ChatEditor {
  ChatEdits(this._ref);

  final Ref _ref;

  /// Whether [chat] is on screen here, its controller this device's to
  /// update.
  bool _openHere(ChatState chat) =>
      _ref.read(selectedChatIdProvider) == chat.id &&
      !_ref.read(isMirroredChatProvider(chat.id));

  /// Pinning ends a temporary chat, which the title bar of the open one says
  /// — so the write is handed to its controller, or the bar keeps counting
  /// down to an expiry that is no longer there. Only there: reading the
  /// notifier for any other chat builds a controller, and loads a
  /// conversation nobody is looking at.
  @override
  Future<void> setPinned(ChatState chat, bool pinned) async {
    final repo = _ref.read(chatRepositoryProvider);
    final written = await (pinned
        ? repo.pinChat(chat.id, chat)
        : repo.unpinChat(chat.id, chat));
    if (_openHere(chat)) {
      _ref.read(chatControllerProvider(chat.id).notifier).applyState(written);
    }
    _ref.invalidate(chatListProvider);
  }

  @override
  Future<void> retitle(ChatState chat, String title) async {
    await _ref.read(chatRepositoryProvider).retitle(chat.id, title);
    if (_openHere(chat)) {
      _ref.read(chatControllerProvider(chat.id).notifier).applyTitle(title);
    }
    _ref.invalidate(chatListProvider);
  }

  /// Never a mirror: its projects are its home device's. The open
  /// controller holds the chat it read when it was built — project included
  /// — so it is disposed and re-read from where the chat now is.
  @override
  Future<void> move(ChatState chat, String? project) async {
    await _ref.read(chatRepositoryProvider).moveChat(chat.id, project);
    _ref.invalidate(chatControllerProvider(chat.id));
    _ref.invalidate(chatListProvider);
  }

  @override
  Future<void> delete(ChatState chat) async {
    if (_ref.read(selectedChatIdProvider) == chat.id) {
      _ref.read(selectedChatIdProvider.notifier).select(null);
    }
    await _ref.read(chatRepositoryProvider).deleteChat(chat.id);
    _ref.invalidate(chatListProvider);
  }
}

final chatEditsProvider = Provider<ChatEdits>(ChatEdits.new);

Future<void> setChatPinned(WidgetRef ref, ChatState chat, bool pinned) =>
    ref.read(chatEditsProvider).setPinned(chat, pinned);

Future<void> renameChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
) async {
  final title = await promptForText(
    context,
    title: "Rename chat",
    initial: chat.title,
    hint: "Chat title",
    confirmLabel: "Rename",
  );
  if (title == null) return;
  await ref.read(chatEditsProvider).retitle(chat, title);
}

/// File a chat elsewhere and follow it: it has just left the list being
/// shown, and a chat that vanished on being moved reads as a deletion.
Future<void> moveChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
) async {
  final projects = await ref.read(chatRepositoryProvider).listProjects();
  if (!context.mounted) return;
  final picked = await pickProject(
    context,
    projects: everyProject(projects),
    current: chat.project,
  );
  if (picked == null || picked.project == chat.project) return;
  await ref.read(chatEditsProvider).move(chat, picked.project);
  ref
      .read(selectedProjectProvider.notifier)
      .select(localProject(picked.project));
}

Future<void> deleteChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
) async {
  final confirmed = await confirm(
    context,
    title: "Delete chat?",
    message: "Delete \"${chat.title.orUntitled}\"? This cannot be undone.",
    confirmLabel: "Delete",
    destructive: true,
  );
  if (!confirmed) return;
  await ref.read(chatEditsProvider).delete(chat);
}
