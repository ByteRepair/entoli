import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/chat_meta.dart";
import "../domain/models.dart";
import "../providers.dart";
import "chat_controller.dart";
import "chat_edits.dart";
import "settings/scope.dart";

/// A chat's settings as its page edits them: a copy of its `meta.json`,
/// written through [at] as the page changes it and saved whole. A new
/// chat's has no [chatId], and its Save hands the [meta] back instead.
class ChatSettingsDraft extends ChangeNotifier {
  ChatSettingsDraft._(
    this.chatId,
    ChatMeta meta, {
    this.project,
    this.state,
    this.workspace,
  }) : meta = meta.copy();

  /// A chat not made yet: [initial] copied, so backing out leaves it as it
  /// was.
  ChatSettingsDraft.newChat(ChatMeta initial, {String? project})
    : this._(null, initial, project: project);

  final String? chatId;
  final ChatMeta meta;

  /// The project the chat is in, which its settings inherit from.
  final String? project;

  /// Read with the meta so the TTL anchor is written again on Save without
  /// waiting for a turn; null where the chat has no `state.json`.
  final ChatState? state;

  /// The chat's own workspace, null for a mirror, whose files are on its
  /// home device.
  final String? workspace;

  bool get pinned => state?.pinned ?? false;

  bool edited = false;

  /// Where the page's rows read and write the draft.
  late final ChatAddress at = ChatAddress(
    meta.doc,
    project: project,
    onChange: () {
      edited = true;
      notifyListeners();
    },
  );
}

/// Loads, saves and deletes a chat's [ChatSettingsDraft].
class ChatSettingsEditor {
  ChatSettingsEditor(this._ref);

  final Ref _ref;

  Future<ChatSettingsDraft> load(String chatId) async {
    final repo = _ref.read(chatRepositoryProvider);
    final (meta, project) = await (
      repo.loadMeta(chatId),
      repo.projectOf(chatId),
    ).wait;
    ChatState? state;
    try {
      state = (await repo.openChat(chatId)).state;
    } catch (_) {
      // No `state.json`: the next turn's save anchors the TTL instead.
      state = null;
    }
    return ChatSettingsDraft._(
      chatId,
      meta,
      project: project,
      state: state,
      workspace: _ref.read(isMirroredChatProvider(chatId))
          ? null
          : _ref.read(appConfigProvider).workspaceDir(chatId, project: project),
    );
  }

  Future<void> save(ChatSettingsDraft draft) async {
    final chatId = draft.chatId!;
    final repo = _ref.read(chatRepositoryProvider);
    try {
      await repo.saveMeta(chatId, draft.meta);
      // Anchored again at once, so the countdown shows without waiting for a
      // turn; the write decides the anchor, so the bar is told what it wrote.
      if (draft.state case final state?) {
        final written = await repo.saveState(state, reanchor: true);
        // A mirror's controller hears it from the home device.
        if (!_ref.read(isMirroredChatProvider(chatId))) {
          _ref
              .read(chatControllerProvider(chatId).notifier)
              .applyState(written);
        }
      }
      draft.edited = false;
    } finally {
      // The sidebar shows whatever half of a failed save landed.
      _ref.invalidate(chatListProvider);
    }
  }

  /// Works with no `state.json` to read, which is when a broken chat is
  /// most wanted gone.
  Future<void> delete(String chatId) =>
      _ref.read(chatEditsProvider).deleteById(chatId);
}

final chatSettingsEditorProvider = Provider(ChatSettingsEditor.new);
