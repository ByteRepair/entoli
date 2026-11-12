import "package:flutter/foundation.dart" show ChangeNotifier;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/chat_meta.dart";
import "../domain/models.dart";
import "../domain/room/room_state.dart";
import "../providers.dart";
import "chat_controller.dart";
import "composer.dart";
import "mirror_controller.dart";

/// What a chat's session asks of the frontend it is drawn in: a field's text
/// to hold the composer's words, a line said to the user, voice mode opened.
/// `main` binds it.
abstract interface class ChatSessionHost {
  ComposerText newText();

  void say(String message);

  void openVoice(String chatId);

  /// Voice mode with no chat yet, the first word making one under [meta].
  void startVoiceChat(ChatMeta meta);
}

final chatSessionHostProvider = Provider<ChatSessionHost>(
  (ref) => throw UnimplementedError("bound where the app is assembled"),
);

/// One chat as a frontend works with it, apart from how it is drawn: where
/// its turns are read from and driven through — this device's controller,
/// or a paired device's mirror — and its composer, the words and what they
/// are sent with. Kept while something reads it, so a frontend that is not a
/// widget tree — the native shell's — drives a chat the way the Flutter page
/// does, and both send the same way.
class ChatSession {
  ChatSession(this._ref, this.chatId) {
    text = _ref.read(chatSessionHostProvider).newText();
    composer = ComposerModel(
      text,
      pick: (kind) => _ref.read(attachmentPickerProvider).pick(kind),
    );
  }

  final Ref _ref;
  final String chatId;

  /// The composer's words, and the model over them.
  late final ComposerText text;
  late final ComposerModel composer;

  bool get mirrored => _ref.read(isMirroredChatProvider(chatId));

  /// Where the chat's view state is read from.
  ProviderListenable<ChatViewState> get source => mirrored
      ? mirrorChatControllerProvider(chatId)
      : chatControllerProvider(chatId);

  /// What its turns and edits are driven through: null for a mirror whose
  /// home device is offline, which can be read and not written to.
  TurnDriver? get driver {
    if (!mirrored) return _ref.read(chatControllerProvider(chatId).notifier);
    final online = _ref
        .read(remoteChatsProvider)
        .any((c) => c.chatId == chatId && c.online);
    return online
        ? _ref.read(mirrorChatControllerProvider(chatId).notifier)
        : null;
  }

  /// [text] sent into [view]'s turn, or queued after it. Something said
  /// over a browser upload waiting on the user is their answer to it: the
  /// chooser is cancelled, as dismissing its dialog would, and the agent is
  /// told. A message a paired device did not take is said.
  Future<void> send(
    TurnDriver driver,
    String text,
    List<Attachment> attachments, {
    bool queue = false,
  }) async {
    final browser = _ref.read(agentBrowserProvider);
    if (browser.available && browser.configured) {
      browser
          .tab(chatId)
          .cancelUpload(
            why: "The user sent a message instead of choosing a file.",
          );
    }
    try {
      await driver.send(text, attachments: attachments, queue: queue);
    } on Undelivered catch (e) {
      _ref.read(chatSessionHostProvider).say(e.message);
    }
  }

  /// The composer bound to [view]'s turn through [driver]: Send and Queue,
  /// Stop, the steer rule, voice mode, and the project the menus offer.
  /// [sent] runs before each send, for a page that follows the reply.
  ComposerBinding binding(
    ChatViewState view,
    TurnDriver driver, {
    String? device,
    void Function()? sent,
  }) {
    final project = view.chat?.state.project;
    final config = _ref.read(appConfigProvider);
    Future<void> go(String text, List<Attachment> files, {bool queue = false}) {
      sent?.call();
      return send(driver, text, files, queue: queue);
    }

    return ComposerBinding(
      agentSpeaking: view.roomPhase == RoomPhase.agentSpeaking,
      onSend: go,
      onQueue: (text, files) => go(text, files, queue: true),
      steers: driver.steers,
      onAbort: driver.abort,
      project: project,
      device: device,
      onVoice: mirrored
          ? null
          : () => _ref.read(chatSessionHostProvider).openVoice(chatId),
      workspace: mirrored
          ? null
          : config.workspaceDir(chatId, project: project),
      workspaceHome: mirrored
          ? null
          : config.projectWorkspaceDir(project: project),
    );
  }

  void dispose() {
    composer.dispose();
    if (text case final ChangeNotifier field) field.dispose();
  }
}

/// The session of [chatId], while anything reads it.
final chatSessionProvider = Provider.autoDispose.family<ChatSession, String>((
  ref,
  chatId,
) {
  final session = ChatSession(ref, chatId);
  ref.onDispose(session.dispose);
  return session;
});
