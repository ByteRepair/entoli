import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/speech_text.dart";
import "../../domain/voice.dart";
import "../../providers.dart";

/// What the preview in settings says, and the id it is read under. A question
/// and an answer's worth: enough to hear a voice's rhythm rather than one word
/// of it.
const previewSpeech = "Hi, how are you? What can I do for you?";
const previewId = "preview";

/// Reading one thing out loud: a message, from the button under it, or the
/// preview line, from the button beside the voice picker. The state is what is
/// being read, or null.
///
/// One of them, deliberately. Two notifiers would be two voices talking over
/// each other, and the second would have to load a second copy of the model.
///
/// **Not voice mode.** There is no microphone, no recognition model and no
/// conversation: the session is the speech model and nothing else, and it is
/// let go the moment the message has been read — a speech model is tens of
/// megabytes of a phone's memory to hold for a button nobody may press again.
/// Voice mode is a way of having the conversation; this is a way of hearing
/// one message of one.
class ReadAloud extends Notifier<String?> {
  VoiceSession? _session;
  StreamSubscription<VoiceEvent>? _events;

  @override
  String? build() {
    ref.onDispose(() => unawaited(_close()));
    return null;
  }

  /// Read [said] out under [id], or stop if [id] is what is already being read.
  /// Returns what went wrong, or null — a snack bar belongs to the page that
  /// has a `Scaffold`, not to a notifier.
  Future<String?> toggle(String id, String said) async {
    final reading = state;
    await stop();
    if (reading == id) return null;

    final settings = ref.read(appSettingsProvider);
    final speaking = voicePicks(
            settings, ref.read(agentBackendProvider), ref.read(voiceProvider))
        .speaking;
    if (speaking == null) return "No speech model is picked.";
    final text = speakable(said);
    if (text.trim().isEmpty) return null;

    // Before the loading, so the button says what it is doing while a hundred
    // megabytes of model are read off a phone's disk.
    state = id;
    try {
      final session = await ref
          .read(voiceProvider)
          .start(
            speaking: speaking,
            speaker: settings.voiceSpeaker,
            language: settings.voiceLanguage,
          );
      // Tapped again while it loaded, or the app was left. The session is the
      // only thing that has to be undone; the state already is.
      if (state != id) {
        await session.dispose();
        return null;
      }
      _session = session;
      // The session is what knows when the last sentence has actually been
      // heard — nothing here can tell generating from playing.
      _events = session.events.listen((event) {
        if (event is VoiceFellSilent) unawaited(stop());
      });
      // Sentence by sentence, so the first is being read while the rest is
      // still being generated. The same split the reply gets in voice mode.
      final sentences = SentenceSplitter();
      final pieces = [...sentences.add(text), sentences.flush()]
          .where((s) => s.trim().isNotEmpty);
      for (final sentence in pieces) {
        await session.speak(sentence);
      }
    } catch (e) {
      await stop();
      return "$e";
    }
    return null;
  }

  Future<void> stop() async {
    if (state == null) return;
    state = null;
    await _close();
  }

  Future<void> _close() async {
    final session = _session;
    _session = null;
    await _events?.cancel();
    _events = null;
    await session?.dispose();
  }
}

final readAloudProvider = NotifierProvider<ReadAloud, String?>(ReadAloud.new);

/// Read [said] out under [id], or stop if it is what is already being read,
/// and say in a snack bar what went wrong. Here rather than on the notifier
/// for the reason [ReadAloud.toggle] returns a string: the `Scaffold` is the
/// page's, and both of the buttons that read something out want the same
/// sentence over it.
Future<void> readAloud(
    BuildContext context, WidgetRef ref, String id, String said) async {
  final failed = await ref.read(readAloudProvider.notifier).toggle(id, said);
  if (failed == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed)));
}
