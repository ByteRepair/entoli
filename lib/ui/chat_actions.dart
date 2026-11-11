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
import "../app/chat_edits.dart";
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
  AppAction.pinChat =>
    ref.read(chatEditsProvider).setPinned(chat, !chat.pinned),
  AppAction.renameChat => renameChat(context, ref, chat),
  AppAction.moveChat => moveChat(context, ref, chat),
  AppAction.deleteChat => deleteChat(context, ref, chat),
  _ => throw ArgumentError.value(command, "command", "not a chat command"),
};

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
