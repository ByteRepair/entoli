import "dart:async";

import "../../domain/voice.dart";
import "played_speaker.dart";

/// The speaking half for a provider's speech model: each sentence a request,
/// played by [PlayingSpeaker]. Needs no sherpa, so it is every platform's.
class RemoteSpeaker extends PlayingSpeaker {
  RemoteSpeaker(this._synthesize);

  final Synthesize _synthesize;

  /// The last sentence asked for, so the next waits for it: concurrent
  /// requests come back in whatever order the network likes.
  Future<void> _asked = Future.value();

  @override
  Future<void> speak(String text) async {
    if (!usable || text.trim().isEmpty) return;
    final batch = queued();
    _asked = _asked.then((_) => _say(batch, text));
  }

  Future<void> _say(int batch, String text) async {
    // Stopped while it waited its turn: nobody wants it any more.
    if (!usable || batch != generation) return;
    try {
      final audio = await _synthesize(text);
      audio.isEmpty ? lost(batch) : generated(batch, audio);
    } catch (e) {
      lost(batch, "Speech failed: $e");
    }
  }
}
