import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/chat_intents.dart" show ChatEditor;
import "../domain/models.dart";
import "../providers.dart";
import "chat_controller.dart";
import "selection.dart";

/// The writes behind a chat's edits, with no dialog: what the row menu,
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
