/// What the app has open — which project, which chat in it — and the
/// actions that change either: app state, read and changed from several pages.
library;

import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/log.dart";
import "../domain/chat_meta.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "chat/chat_controller.dart";
import "widgets/nav_drawer.dart";

/// Which chat the pane is showing, or null for the new-chat screen. **Null is
/// a screen rather than a chat to be made**: nothing is written until there is
/// something to say — see "Nothing selected is a new chat".
class SelectedChatId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;

  /// Make a chat in the project being shown and select it. **The one place a
  /// chat is created from the UI** — a method here rather than a function
  /// beside the widgets because not every caller has a `WidgetRef`.
  ///
  /// [meta] is the settings it should run its first turn under, for a screen
  /// that offered them before there was a chat to write them on. Null is a
  /// chat that could not be made, which is already logged.
  Future<String?> create({ChatMeta? meta}) async {
    try {
      final at = ref.read(selectedProjectProvider);
      // A paired device's project is not a directory here; [startChatWith]
      // starts a chat there.
      if (at.device != null) {
        throw StateError("${at.project} is on ${at.device}");
      }
      final chat = await ref
          .read(chatRepositoryProvider)
          .createChat(project: at.project, meta: meta);
      state = chat.state.id;
      ref.invalidate(chatListProvider);
      return chat.state.id;
    } catch (e) {
      logFailure("chat", "could not start a chat", e);
      return null;
    }
  }
}

final selectedChatIdProvider = NotifierProvider<SelectedChatId, String?>(
  SelectedChatId.new,
);

/// Which project the sidebar is showing, on whichever device, and where a new
/// chat goes. This device's default project is what the app opens in.
class SelectedProject extends Notifier<ProjectRef> {
  @override
  ProjectRef build() => localProject(null);

  void select(ProjectRef project) => state = project;
}

final selectedProjectProvider = NotifierProvider<SelectedProject, ProjectRef>(
  SelectedProject.new,
);

void openChat(BuildContext context, WidgetRef ref, String chatId) {
  ref.read(selectedChatIdProvider.notifier).select(chatId);
  closeNavDrawer(context);
}

/// Switch to a project. A chat of the one being left is not in the list any
/// more, so keeping it selected would leave the pane showing something the
/// sidebar denies — and dropping it is also what starts a chat in the project
/// just picked. The switcher, the empty chat's badges and deleting a project
/// are all this.
void selectProject(WidgetRef ref, ProjectRef project) {
  ref.read(selectedProjectProvider.notifier).select(project);
  ref.read(selectedChatIdProvider.notifier).select(null);
}

/// Go to the new-chat screen, with the drawer it was pressed in closed — the
/// sidebar's button and the assistant gesture. Nothing is created: the screen
/// makes a chat when the first thing is said in it.
void openNewChat(BuildContext context, WidgetRef ref) {
  ref.read(selectedChatIdProvider.notifier).select(null);
  closeNavDrawer(context);
}

/// The new-chat screen in [project], null being the default one: the
/// new-chat shortcuts, each of which names where the chat goes.
void openNewChatIn(BuildContext context, WidgetRef ref, String? project) {
  selectProject(ref, localProject(project));
  closeNavDrawer(context);
}

/// Pinning ends a temporary chat, which the title bar of the open one says —
/// so where [open], the write is handed to its controller, or the bar keeps
/// counting down to an expiry that is no longer there. Only there: reading the
/// notifier for any other chat builds a controller, and loads a conversation
/// nobody is looking at.
Future<void> setChatPinned(
  WidgetRef ref,
  ChatState chat,
  bool pinned, {
  required bool open,
}) async {
  final repo = ref.read(chatRepositoryProvider);
  final written = await (pinned
      ? repo.pinChat(chat.id, chat)
      : repo.unpinChat(chat.id, chat));
  if (open) {
    ref.read(chatControllerProvider(chat.id).notifier).applyState(written);
  }
  ref.invalidate(chatListProvider);
}

/// Pin the open chat, or unpin it if it is pinned. Nothing for the new-chat
/// screen or a mirror, whose state is the home device's.
Future<void> toggleOpenChatPin(WidgetRef ref) async {
  final id = ref.read(selectedChatIdProvider);
  if (id == null || ref.read(isMirroredChatProvider(id))) return;
  final chat = ref.read(chatControllerProvider(id)).chat?.state;
  if (chat == null) return;
  await setChatPinned(ref, chat, !chat.pinned, open: true);
}

/// Start a chat and say the first thing in it. The new-chat screen's composer
/// is the one caller: it holds the text, the files and the settings until
/// there is a chat to put them in, and this is that moment. False is a chat
/// that could not be made, so that the caller can put back what it cleared.
///
/// The turn is deliberately not awaited — it runs for as long as the model
/// takes, and the page has to arrive on the message rather than after the
/// reply. Nothing waits on the controller having read the chat back either:
/// `send` waits on that itself, which is what [ChatController] owes anything
/// that drives a turn it has only just built.
Future<bool> startChatWith(
  WidgetRef ref,
  String text, {
  List<Attachment> attachments = const [],
  ChatMeta? meta,
}) async {
  final at = ref.read(selectedProjectProvider);
  if (at.device != null) {
    // Made there, which runs the turn: this device follows it, holding it.
    final reply = await ref
        .read(syncHubProvider)
        .startRemoteChat(at, text, attachments: attachments);
    final id = reply?.chatId;
    if (id == null) return false;
    ref.read(selectedChatIdProvider.notifier).select(id);
    return true;
  }
  final id = await ref.read(selectedChatIdProvider.notifier).create(meta: meta);
  if (id == null) return false;
  unawaited(
    ref
        .read(chatControllerProvider(id).notifier)
        .send(text, attachments: attachments),
  );
  return true;
}
