/// The Flutter frontend's ways to change what is open, each closing the
/// drawer it was pressed in. The state is the core's: `lib/app/selection.dart`.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/selection.dart";
import "../domain/chat_meta.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "widgets/nav_drawer.dart";

export "../app/selection.dart";

void openChat(BuildContext context, WidgetRef ref, String chatId) {
  ref.read(selectedChatIdProvider.notifier).select(chatId);
  closeNavDrawer(context);
}

/// Switch to a project: see [SelectedProject.switchTo].
void selectProject(WidgetRef ref, ProjectRef project) =>
    ref.read(selectedProjectProvider.notifier).switchTo(project);

/// Go to the new-chat screen, with the drawer it was pressed in closed — the
/// sidebar's button and the assistant gesture. Nothing is created: the screen
/// makes a chat when the first thing is said in it.
void openNewChat(BuildContext context, WidgetRef ref, {String? prompt}) {
  ref.read(selectedChatIdProvider.notifier).select(null);
  if (prompt != null) ref.read(newChatPromptProvider.notifier).set(prompt);
  closeNavDrawer(context);
}

/// The new-chat screen in [project], null being the default one: the
/// new-chat shortcuts, each of which names where the chat goes.
void openNewChatIn(BuildContext context, WidgetRef ref, String? project) {
  selectProject(ref, localProject(project));
  closeNavDrawer(context);
}

/// Start a chat and say the first thing in it: see [SelectedChatId.start].
Future<bool> startChatWith(
  WidgetRef ref,
  String text, {
  List<Attachment> attachments = const [],
  ChatMeta? meta,
}) => ref
    .read(selectedChatIdProvider.notifier)
    .start(text, attachments: attachments, meta: meta);
