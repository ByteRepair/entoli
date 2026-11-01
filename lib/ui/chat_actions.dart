/// What can be done to one chat from outside it: its sidebar row's menu and
/// the app's Chat menu, which acts on the open one. Each works out for itself
/// whether [ChatState] is the chat on screen — whose controller holds a copy of
/// what is written here — and whether it is a mirror, whose controller is its
/// home device's.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "app_command.dart";
import "chat/chat_controller.dart";
import "selection.dart";
import "widgets/dialogs.dart";

/// The commands that act on one chat, in the order a menu offers them.
const chatCommands = [
  AppCommand.pinChat,
  AppCommand.renameChat,
  AppCommand.moveChat,
  AppCommand.deleteChat,
];

/// Run one of [chatCommands] on [chat].
Future<void> runOnChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
  AppCommand command,
) => switch (command) {
  AppCommand.pinChat => setChatPinned(ref, chat, !chat.pinned),
  AppCommand.renameChat => renameChat(context, ref, chat),
  AppCommand.moveChat => moveChat(context, ref, chat),
  AppCommand.deleteChat => deleteChat(context, ref, chat),
  _ => throw ArgumentError.value(command, "command", "not a chat command"),
};

/// Whether [chat] is on screen here, its controller this device's to update.
bool _openHere(WidgetRef ref, ChatState chat) =>
    ref.read(selectedChatIdProvider) == chat.id &&
    !ref.read(isMirroredChatProvider(chat.id));

/// Pinning ends a temporary chat, which the title bar of the open one says —
/// so the write is handed to its controller, or the bar keeps counting down to
/// an expiry that is no longer there. Only there: reading the notifier for any
/// other chat builds a controller, and loads a conversation nobody is looking
/// at.
Future<void> setChatPinned(WidgetRef ref, ChatState chat, bool pinned) async {
  final repo = ref.read(chatRepositoryProvider);
  final written = await (pinned
      ? repo.pinChat(chat.id, chat)
      : repo.unpinChat(chat.id, chat));
  if (_openHere(ref, chat)) {
    ref.read(chatControllerProvider(chat.id).notifier).applyState(written);
  }
  ref.invalidate(chatListProvider);
}

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
  await ref.read(chatRepositoryProvider).retitle(chat.id, title);
  if (_openHere(ref, chat)) {
    ref.read(chatControllerProvider(chat.id).notifier).applyTitle(title);
  }
  ref.invalidate(chatListProvider);
}

/// File a chat elsewhere and follow it: it has just left the list being
/// shown, and a chat that vanished on being moved reads as a deletion. Never
/// a mirror: its projects are its home device's.
Future<void> moveChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat,
) async {
  final repo = ref.read(chatRepositoryProvider);
  final projects = await repo.listProjects();
  if (!context.mounted) return;
  final picked = await pickProject(
    context,
    projects: everyProject(projects),
    current: chat.project,
  );
  if (picked == null || picked.project == chat.project) return;
  await repo.moveChat(chat.id, picked.project);
  // The open controller holds the chat it read when it was built — project
  // included — so it is disposed and re-read from where the chat now is.
  ref.invalidate(chatControllerProvider(chat.id));
  ref
      .read(selectedProjectProvider.notifier)
      .select(localProject(picked.project));
  ref.invalidate(chatListProvider);
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
  if (ref.read(selectedChatIdProvider) == chat.id) {
    ref.read(selectedChatIdProvider.notifier).select(null);
  }
  await ref.read(chatRepositoryProvider).deleteChat(chat.id);
  ref.invalidate(chatListProvider);
}
