import "package:flutter/foundation.dart" show ChangeNotifier, ValueNotifier;
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/chat_meta.dart";
import "package:entoli_core/model/attachment_picker.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/project.dart";
import "package:entoli_core/transcript/reader.dart" show SettingReader;

import "../providers.dart";
import "composer.dart";
import "selection.dart";

/// The new-chat screen apart from how it is drawn: its composer, the
/// settings the chat it makes will run under, whether one is being made, and
/// how the first message makes it. One for the app while the screen is up.
class NewChatSession {
  NewChatSession(this._ref) {
    text = _ref.read(composerTextProvider)();
    composer = ComposerModel(
      text,
      pick: (kind) => pickAttachments(_ref.read(filePickerProvider), kind),
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

  /// Makes a chat in the selected project and says [said] in it. One that
  /// could not be made puts the message back, since the composer has already
  /// cleared itself, and tells [say].
  Future<void> send(
    String said,
    List<Attachment> attachments, {
    required void Function(String message) say,
  }) async {
    starting.value = true;
    final made = await _ref
        .read(selectedChatIdProvider.notifier)
        .start(said, attachments: attachments, meta: meta.value);
    starting.value = false;
    if (!made) {
      text.edit(said, said.length);
      say("Could not start a chat.");
    }
  }

  /// What stands where the composer goes at [at], what it depends on
  /// watched through [reader]. A paired device's project has its setup and
  /// its voice on that device. [say] is told what did not work, and
  /// [startVoice] opens voice mode whose first word makes a chat under
  /// [meta].
  ComposerSlot slot(
    SettingReader reader,
    ProjectRef at, {
    required void Function(String message) say,
    required void Function(ChatMeta meta) startVoice,
  }) {
    if (starting.value) return const ComposerStarting();
    void go(String said, List<Attachment> files) => send(said, files, say: say);
    if (at.device != null) {
      if (reader.watch(projectFrozenProvider(at))) {
        return const ComposerViewOnly();
      }
      return ComposerReady(
        ComposerBinding(
          agentSpeaking: false,
          onSend: go,
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
        onSend: go,
        project: at.project,
        onVoice: () => startVoice(meta.value),
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
