import "package:flutter/foundation.dart" show ChangeNotifier, ValueNotifier;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/chat_meta.dart";
import "../domain/models.dart";
import "../domain/project.dart";
import "../providers.dart";
import "chat_session.dart" show chatSessionHostProvider;
import "composer.dart";
import "selection.dart";
import "settings/spec.dart" show SettingReader;

/// The new-chat screen apart from how it is drawn: its composer, the
/// settings the chat it makes will run under, whether one is being made, and
/// how the first message makes it. One for the app while the screen is up,
/// so the Flutter page and the native shell drive the same draft.
class NewChatSession {
  NewChatSession(this._ref) {
    text = _ref.read(chatSessionHostProvider).newText();
    composer = ComposerModel(
      text,
      pick: (kind) => _ref.read(attachmentPickerProvider).pick(kind),
    );
    _ref.listen(newChatPromptProvider, (_, prompt) {
      if (prompt == null) return;
      text.edit(prompt, prompt.length);
      // Cleared after the listener: a provider is not written while one
      // notifies.
      Future(() => _ref.read(newChatPromptProvider.notifier).set(null));
    }, fireImmediately: true);
  }

  final Ref _ref;

  late final ComposerText text;
  late final ComposerModel composer;

  /// What the chat this screen makes will run its first turn under. Dies
  /// with the screen: armed app-wide it would land on whatever chat was made
  /// next, from anywhere.
  final meta = ValueNotifier<ChatMeta>(ChatMeta());

  /// A chat being made on a paired device, until it has answered.
  final starting = ValueNotifier<bool>(false);

  /// Makes a chat in the selected project and says [text] in it. One that
  /// could not be made puts the message back, since the composer has already
  /// cleared itself, and says so.
  Future<void> send(String said, List<Attachment> attachments) async {
    starting.value = true;
    final made = await _ref
        .read(selectedChatIdProvider.notifier)
        .start(said, attachments: attachments, meta: meta.value);
    starting.value = false;
    if (!made) {
      text.edit(said, said.length);
      _ref.read(chatSessionHostProvider).say("Could not start a chat.");
    }
  }

  /// What stands where the composer goes at [at], what it depends on
  /// watched through [reader]. A paired device's project has its setup and
  /// its voice on that device.
  ComposerSlot slot(SettingReader reader, ProjectRef at) {
    if (starting.value) return const ComposerStarting();
    if (at.device != null) {
      if (reader.watch(projectFrozenProvider(at))) {
        return const ComposerViewOnly();
      }
      return ComposerReady(
        ComposerBinding(
          agentSpeaking: false,
          onSend: send,
          onAbort: () {},
          project: at.project,
          device: at.device,
        ),
      );
    }
    if (!reader.watch(setupCompleteProvider(at.project))) {
      return const ComposerNeedsSetup();
    }
    return ComposerReady(
      ComposerBinding(
        agentSpeaking: false,
        onSend: send,
        onAbort: () {},
        project: at.project,
        onVoice: () =>
            _ref.read(chatSessionHostProvider).startVoiceChat(meta.value),
      ),
    );
  }

  void dispose() {
    composer.dispose();
    meta.dispose();
    starting.dispose();
    if (text case final ChangeNotifier field) field.dispose();
  }
}

/// The new-chat screen's session, while anything reads it.
final newChatSessionProvider = Provider.autoDispose<NewChatSession>((ref) {
  final session = NewChatSession(ref);
  ref.onDispose(session.dispose);
  return session;
});
