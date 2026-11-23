import "package:flutter/foundation.dart" show ChangeNotifier;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "package:entoli_chat/domain/models.dart";
import "package:entoli_chat/domain/room/room_state.dart";
import "../providers.dart";
import "chat_controller.dart";
import "composer.dart";
import "mirror_controller.dart";
import "package:entoli_chat/app/reader.dart" show SettingReader;

/// One chat apart from how it is drawn: where its turns are read from and
/// driven through — this device's controller, or a paired device's mirror —
/// and its composer, the words and what they are sent with. Kept while
/// something reads it.
class ChatSession {
  ChatSession(this._ref, this.chatId) {
    text = _ref.read(composerTextProvider)();
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
    final online = _ref.read(mirrorHomeProvider(chatId))?.online ?? false;
    return online
        ? _ref.read(mirrorChatControllerProvider(chatId).notifier)
        : null;
  }

  /// [text] sent into [driver]'s turn, or queued after it. Something said
  /// over a browser upload waiting on the user is their answer to it: the
  /// chooser is cancelled, as dismissing its dialog would, and the agent is
  /// told. A message a paired device did not take is told to [say].
  Future<void> send(
    TurnDriver driver,
    String text,
    List<Attachment> attachments, {
    bool queue = false,
    required void Function(String message) say,
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
      say(e.message);
    }
  }

  /// What stands where the composer goes for [view], driven through
  /// [driver], what it depends on watched through [reader]. Bound to the
  /// turn: Send and Queue, Stop, the steer rule, voice mode, and the
  /// project the menus offer. [say] is told what did not get through,
  /// [openVoice] opens voice mode on this chat, and [sent] runs before each
  /// send, for a page that follows the reply.
  ComposerSlot slot(
    SettingReader reader,
    ChatViewState view,
    TurnDriver? driver, {
    required void Function(String message) say,
    required void Function() openVoice,
    String? device,
    void Function()? sent,
  }) {
    final chat = view.chat;
    if (chat == null || driver == null) return const ComposerViewOnly();
    // A mirror's is its home device's to enable.
    if (chat.state.imported) {
      return mirrored ? const ComposerViewOnly() : const ComposerImported();
    }
    if (!mirrored && !reader.watch(setupCompleteProvider(chat.state.project))) {
      return const ComposerNeedsSetup();
    }
    if (view.roomPhase == RoomPhase.waitingOnYou) {
      return const ComposerAnswering();
    }
    final project = chat.state.project;
    final config = _ref.read(appConfigProvider);
    Future<void> go(String text, List<Attachment> files, {bool queue = false}) {
      sent?.call();
      return send(driver, text, files, queue: queue, say: say);
    }

    return ComposerReady(
      ComposerBinding(
        agentSpeaking: view.roomPhase == RoomPhase.agentSpeaking,
        onSend: go,
        onQueue: (text, files) => go(text, files, queue: true),
        steers: driver.steers,
        onAbort: driver.abort,
        project: project,
        device: device,
        // A mirror's voice, and its files, are its home device's.
        onVoice: mirrored ? null : openVoice,
        workspace: mirrored
            ? null
            : config.workspaceDir(chatId, project: project),
        workspaceHome: mirrored
            ? null
            : config.projectWorkspaceDir(project: project),
      ),
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
