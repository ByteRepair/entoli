/// What can be done to one chat from outside it: its sidebar row's menu and
/// the app's Chat menu, which acts on the open one. [open] is the chat on
/// screen, whose controller holds a copy of what is written here; [remote] a
/// mirror, whose writes go to its home device.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "chat/chat_controller.dart";
import "selection.dart";
import "widgets/dialogs.dart";

Future<void> renameChat(
  BuildContext context,
  WidgetRef ref,
  ChatState chat, {
  required bool open,
  bool remote = false,
}) async {
  final title = await promptForText(
    context,
    title: "Rename chat",
    initial: chat.title,
    hint: "Chat title",
    confirmLabel: "Rename",
  );
  if (title == null) return;
  await ref.read(chatRepositoryProvider).retitle(chat.id, title);
  if (open && !remote) {
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
  ChatState chat, {
  required bool open,
}) async {
  final confirmed = await confirm(
    context,
    title: "Delete chat?",
    message: "Delete \"${chat.title.orUntitled}\"? This cannot be undone.",
    confirmLabel: "Delete",
    destructive: true,
  );
  if (!confirmed) return;
  if (open) ref.read(selectedChatIdProvider.notifier).select(null);
  await ref.read(chatRepositoryProvider).deleteChat(chat.id);
  ref.invalidate(chatListProvider);
}
