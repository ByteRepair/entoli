import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:audioplayers/audioplayers.dart";
import "package:path/path.dart" as p;

import "voice_strategies.dart";

/// Where a spoken sentence is written on its way to the player. Genuinely
/// disposable, so the system's own temporary directory rather than the cache
/// the models are unpacked into — which on Android is deliberately the
/// *non*-evictable one, so that a downloaded model is never thrown away, and is
/// the wrong home for a WAV that lives for a sentence.
String get _speechDir => p.join(Directory.systemTemp.path, "entoli-speech");

/// A [Speaker] whose audio is made somewhere else — a sherpa worker, a
/// provider — and played here: files written to a temp directory and played
/// through `audioplayers`. A subclass hands each sentence over with [queued]
/// and reports back with [generated], [lost] or [broke]. [SpeechSilent] is
/// emitted when the queue has drained and nothing is pending; [SpeechFailed]
/// once the engine rather than the sentence is what failed — see
/// [SpeechFailures].
abstract class PlayingSpeaker implements Speaker {
  PlayingSpeaker() {
    _player.onPlayerComplete.listen((_) => unawaited(_playNext()));
    unawaited(_open());
  }

  final _player = AudioPlayer();
  final _signals = StreamController<SpeechSignal>();

  /// Generated audio waiting its turn, and what is playing now. Speech is
  /// generated a sentence ahead of being heard, so there is always a queue.
  final _queue = <String>[];
  var _playing = false;

  /// The file being played, kept until something else is. `play` returns when
  /// playback *starts*, so deleting it there deleted a file still being read.
  String? _played;

  /// Bumped by [stop]. Audio generated before it is dropped rather than played
  /// into a silence the user asked for.
  var _generation = 0;
  int get generation => _generation;

  /// Sentences handed over that have not come back as audio yet.
  var _pending = 0;

  /// See [SpeechFailures]: one sentence lost is not a broken engine.
  final _failures = SpeechFailures();

  var _closed = false;
  var _failed = false;

  /// Whether a sentence handed over now could still be heard.
  bool get usable => !_closed && !_failed;

  /// Nothing generating, nothing queued, nothing playing — which is what there
  /// is to report as silence, and what the controller puts the microphone back
  /// on the strength of.
  bool get _silent => _pending == 0 && _queue.isEmpty && !_playing;

  Future<void> _open() async {
    // Once per session rather than once per sentence, and emptied on the way
    // in: a session killed mid-reply leaves its files behind, and nothing else
    // ever comes back for them.
    final speech = Directory(_speechDir);
    if (speech.existsSync()) await speech.delete(recursive: true);
    await speech.create(recursive: true);
  }

  @override
  Stream<SpeechSignal> get signals => _signals.stream;

  /// One sentence is on its way. Answers the batch it belongs to, which is
  /// what the answer must name.
  int queued() {
    _pending++;
    return _generation;
  }

  /// A sentence of [generation] as a WAV.
  void generated(int generation, Uint8List audio) {
    if (!usable || generation != _generation) return;
    _pending--;
    _failures.spoke();
    unawaited(_enqueue(audio));
  }

  /// The engine would not say that sentence, or said it in no audio at all.
  /// Named by the batch it was queued under, so one arriving after a stop is
  /// not counted against the batch that replaced it. [why] is what is said if
  /// this is the loss that makes it the engine.
  void lost(int generation, [String? why]) {
    if (!usable || generation != _generation) return;
    _dropped(why);
  }

  /// The engine itself: nothing outstanding is coming. Left counted, the
  /// session would never say it had finished. Everything held or playing is
  /// dead, and what arrives later belongs to an engine this side will never
  /// see.
  void broke(String message) {
    if (!usable) return;
    _failed = true;
    _pending = 0;
    for (final path in _queue) {
      unawaited(_discard(path));
    }
    _queue.clear();
    _playing = false;
    unawaited(_player.stop());
    _signals.add(SpeechFailed(message));
  }

  /// One sentence will not be heard. The session still has to be told when the
  /// rest of the reply has been.
  void _dropped([String? why]) {
    if (_pending > 0) _pending--;
    if (_failures.dropped()) {
      broke(why ?? "Speech playback keeps failing.");
    } else if (_silent) {
      _signals.add(const SpeechSilent());
    }
  }

  Future<void> _enqueue(Uint8List audio) async {
    // shortcut: named .wav because WAV is what is asked of a provider; sniff
    // the bytes if one turns out to send something else.
    final path = p.join(_speechDir, "${DateTime.now().microsecondsSinceEpoch}.wav");
    await File(path).writeAsBytes(audio);
    _queue.add(path);
    if (!_playing) await _playNext();
  }

  Future<void> _playNext() async {
    if (!usable) return;
    await _discardPlayed();
    if (_queue.isEmpty) {
      if (_playing) {
        _playing = false;
        if (_pending == 0) _signals.add(const SpeechSilent());
      }
      return;
    }
    final next = _queue.removeAt(0);
    _playing = true;
    _played = next;
    try {
      await _player.play(DeviceFileSource(next));
    } catch (_) {
      // One file the player would not take is one sentence rather than the
      // engine, and the rest of the reply is still worth hearing.
      _playing = false;
      _dropped();
      if (!_failed) await _playNext();
    }
  }

  Future<void> _discardPlayed() async {
    final done = _played;
    _played = null;
    if (done != null) await _discard(done);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pending = 0;
    // A reply the user cut off is not a run of sentences the engine lost.
    _failures.spoke();
    for (final path in _queue) {
      unawaited(_discard(path));
    }
    _queue.clear();
    _playing = false;
    await _player.stop();
    await _discardPlayed();
  }

  Future<void> _discard(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _player.stop();
    await _player.dispose();
    await _signals.close();
  }
}
