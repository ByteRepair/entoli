import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:entoli_chat/app/storage.dart" show fileSystemProvider;
import "package:entoli_chat/data/chat_share.dart";
import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/domain/project.dart" show localProject;
import "../providers.dart";
import "selection.dart";

/// Sharing a chat as a link, and taking one in: what the share dialog and
/// the incoming link run. Enabling an imported chat is `ChatEdits.enable`.
class ChatShares {
  ChatShares(this._ref);

  final Ref _ref;

  /// [chat] as something to share, wherever it is.
  Future<ChatShareSource> source(ChatState chat) async => ChatShareSource(
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

  /// [zip] as a new chat in the project on screen, or the default one where
  /// that is a paired device's, opened. Null where it is not a shared chat.
  Future<String?> import(Uint8List zip) async {
    final shown = _ref.read(selectedProjectProvider);
    final project = shown.device == null ? shown.project : null;
    final id = await importShare(
      zip,
      _ref.read(chatStoreProvider),
      _ref.read(fileSystemProvider),
      project: project,
    );
    if (id == null) return null;
    _ref.invalidate(chatListProvider);
    _ref.read(selectedProjectProvider.notifier).select(localProject(project));
    _ref.read(selectedChatIdProvider.notifier).select(id);
    return id;
  }
}

final chatSharesProvider = Provider<ChatShares>(ChatShares.new);
