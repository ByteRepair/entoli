import "dart:io";
import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/chat_share.dart";
import "../domain/chat_share.dart";
import "../domain/models.dart";
import "../domain/project.dart" show localProject;
import "../providers.dart";
import "chat_controller.dart";
import "selection.dart";

/// Sharing a chat as a link, and taking one in: what the share dialog, the
/// incoming link and the imported chat's bar run.
class ChatShares {
  ChatShares(this._ref);

  final Ref _ref;

  Future<ShareCandidates> candidates(ChatState chat) async => shareCandidates(
    _ref.read(appConfigProvider),
    chat.id,
    project: await _ref.read(chatRepositoryProvider).projectOf(chat.id),
  );

  /// What each of [chat]'s artifacts is called on its card, by id.
  Future<Map<String, String>> artifactTitles(ChatState chat) async {
    final loaded = await _ref.read(chatStoreProvider).load(chat.id);
    return {
      for (final message in loaded.messages)
        for (final part in message.parts)
          if (part case ArtifactPart(:final artifactId, :final title))
            artifactId: title,
    };
  }

  Future<SharePack> pack(
    ChatState chat, {
    required Set<String> workspace,
    required Set<String> artifacts,
  }) async => packShare(
    _ref.read(appConfigProvider),
    chat.id,
    project: await _ref.read(chatRepositoryProvider).projectOf(chat.id),
    workspace: workspace,
    artifacts: artifacts,
  );

  /// [zip] as a new chat in the project on screen, or the default one where
  /// that is a paired device's, opened. Null where it is not a shared chat.
  Future<String?> import(Uint8List zip) async {
    final shown = _ref.read(selectedProjectProvider);
    final project = shown.device == null ? shown.project : null;
    final id = await importShare(
      zip,
      _ref.read(appConfigProvider),
      project: project,
    );
    if (id == null) return null;
    await _ref.read(chatStoreProvider).lockResources(id);
    _ref.invalidate(chatListProvider);
    _ref.read(selectedProjectProvider.notifier).select(localProject(project));
    _ref.read(selectedChatIdProvider.notifier).select(id);
    return id;
  }

  /// Lets [chat] run. Without [keepWorkspace] the files that came with it go
  /// first, so only the conversation is trusted.
  Future<void> enable(ChatState chat, {required bool keepWorkspace}) async {
    final repo = _ref.read(chatRepositoryProvider);
    if (!keepWorkspace) {
      final project = await repo.projectOf(chat.id);
      final dir = Directory(
        _ref.read(appConfigProvider).workspaceDir(chat.id, project: project),
      );
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
    final written = await repo.saveState(chat.copyWith(imported: false));
    _ref.read(chatControllerProvider(chat.id).notifier).applyState(written);
    _ref.invalidate(chatListProvider);
  }
}

final chatSharesProvider = Provider<ChatShares>(ChatShares.new);
