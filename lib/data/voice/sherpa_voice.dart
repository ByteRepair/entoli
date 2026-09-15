import "dart:async";
import "dart:io";
import "dart:isolate";
import "dart:math" as math;
import "package:audioplayers/audioplayers.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;
import "package:record/record.dart";
import "package:sherpa_onnx/sherpa_onnx.dart" as sherpa;

import "../../domain/loudness.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "pcm.dart";
import "voice_strategies.dart";
import "wav.dart";

/// Listening and speaking through sherpa-onnx: the desktops' answer, and the
/// fallback on an Android whose system recognizer cannot be used — see
/// `AndroidVoice`. `start` builds a [SherpaListener] and a [SherpaSpeaker] and
/// hands them to a [ComposedVoiceSession], which forwards both halves' events.
/// See "Hearing and speaking" in CLAUDE.md for the two-worker design.
class SherpaVoice extends Voice {
  SherpaVoice(this._store, this._cacheDir);

  final VoiceModelStore _store;

  /// Where the Silero model is unpacked to. The bundled asset cannot be given
  /// to sherpa as bytes: every model it takes, it takes as a path.
  final String _cacheDir;

  static const _vadAsset = "assets/models/silero_vad.onnx";

  @override
  Future<VoiceSession> start({
    RecognitionModel? recognition,
    required SpeechModel speech,
    int speaker = 0,
    String? language,
  }) async {
    final listener =
        recognition == null ? null : await sherpaListener(recognition);
    return composeSession(listener, sherpaSpeaker(speech, speaker));
  }

  /// The sherpa listening half for one recognition model. Shared with
  /// `AndroidVoice`, which holds a [SherpaVoice] and composes one when a
  /// downloaded model rather than the system recognizer is what was picked.
  ///
  /// Everything that can refuse, before the worker is spawned: a spawn
  /// returns as soon as the isolate has sent its port back, which is
  /// before it has loaded its model, so a refusal after this point is a
  /// hundred megabytes read off a disk and freed again.
  Future<SherpaListener> sherpaListener(RecognitionModel recognition) async {
    final listenDir = await _store.directoryOf(recognition);
    if (listenDir == null) throw StateError("${recognition.name} is not downloaded.");
    final recorder = await openMicrophone();
    final vad = await _vadPath();
    final worker = await Worker.spawn(_listenWorker, (vad, recognition, listenDir));
    return SherpaListener(recorder, worker);
  }

  /// The sherpa speaking half for one speech model, for the same reason as
  /// [sherpaListener].
  Future<SherpaSpeaker> sherpaSpeaker(SpeechModel speech, int speaker) async {
    final speakDir = await _store.directoryOf(speech);
    if (speakDir == null) throw StateError("${speech.name} is not downloaded.");
    final worker = await Worker.spawn(_speakWorker, (speech, speakDir, speaker));
    return SherpaSpeaker(worker);
  }

  /// The Silero model on disk, copied out of the bundle the first time: every
  /// model sherpa takes, it takes as a path.
  Future<String> _vadPath() async {
    final path = p.join(_cacheDir, "silero_vad.onnx");
    final file = File(path);
    if (!await file.exists()) {
      final data = await rootBundle.load(_vadAsset);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return path;
  }
}

/// Where a spoken sentence is written on its way to the player. Genuinely
/// disposable, so the system's own temporary directory rather than the cache
/// the models are unpacked into — which on Android is deliberately the
/// *non*-evictable one, so that a downloaded model is never thrown away, and is
/// the wrong home for a WAV that lives for a sentence.
String get _speechDir => p.join(Directory.systemTemp.path, "entoli-speech");

/// The sherpa listening half: a microphone, Silero VAD, and an offline
/// recognizer, in one worker isolate. The gate, the level and the event stream
/// are [MicrophoneListener]'s; what is here is the recorder and the worker.
///
/// **Silero says whether it is a voice, not whose.** A television two rooms
/// away is speech to it, and so was a turn — the same complaint the system
/// recogniser answered with the gate, arriving here for the same reason. So
/// this measures what it hands over: one reading per detector window, which is
/// 32 ms of audio whatever size the platform's chunks are, on the [decibels]
/// scale rather than the service's.
class SherpaListener extends MicrophoneListener {
  SherpaListener(this._recorder, this._worker) : super(LoudnessGate()) {
    _worker.messages.listen(_fromWorker);
  }

  final AudioRecorder _recorder;
  final Worker _worker;

  StreamSubscription<Uint8List>? _mic;

  /// Whole VAD windows only: what the microphone hands over is however much it
  /// had, and the detector wants 512 samples at a time.
  final _window = Float32List(_windowSize);
  var _filled = 0;
  var _square = 0.0;

  final _pcm = Pcm16Reader();

  /// The inherited [listening] is what the early return compares against rather
  /// than `_mic`: opening the microphone is a platform call, so a shut arriving
  /// while an open is still in flight would otherwise find `_mic` null, read
  /// that as already shut, and leave a recorder running for the session.
  @override
  Future<void> setListening(bool on, {bool finish = false}) async {
    if (closed || on == listening) return;
    asked(on);
    if (!on) {
      // The detector is holding whatever has not fallen silent yet, and no more
      // audio is coming to end it. Flushed rather than dropped where the
      // microphone closed because the sentence was over.
      if (finish) _worker.send(("flush",));
      await _mic?.cancel();
      _mic = null;
      await _recorder.stop();
      _filled = 0;
      _square = 0;
      return;
    }
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // The reply comes out of the same device the microphone is on. The
        // microphone is shut while one is being read out, so this is belt and
        // braces rather than the thing keeping the model from hearing itself.
        echoCancel: true,
        noiseSuppress: true,
      ));
      // Shut while this was opening, which is a Talk button let go inside the
      // platform's own latency. What was asked for last wins.
      if (closed || !listening) {
        await _recorder.stop();
        return;
      }
      _mic = stream.listen(_onAudio, onError: (Object e) => fail("$e"));
    } catch (e) {
      fail("$e");
    }
  }

  void _onAudio(Uint8List bytes) {
    if (closed) return;
    for (final value in _pcm.read(bytes)) {
      _square += value * value;
      _window[_filled++] = value;
      if (_filled < _windowSize) continue;
      _worker.send(("audio", _window));
      // Per window rather than per chunk, so a reading is always the same
      // length of time: the gate counts readings out, and how much audio the
      // platform hands over at once is the platform's business.
      measured(decibels(math.sqrt(_square / _windowSize)));
      _filled = 0;
      _square = 0;
    }
  }

  void _fromWorker(Object? message) {
    switch (message) {
      case ("heard", final String text):
        heard(text);
      case ("failed", final String message):
        fail(message);
    }
  }

  @override
  Future<void> dispose() async {
    closed = true;
    await _mic?.cancel();
    await _recorder.stop();
    _recorder.dispose();
    _worker.close();
    disposeParts();
  }

  /// Silero's window, and so the size of every frame handed to the worker.
  static const _windowSize = 512;
}

/// The sherpa speaking half: an offline TTS in one worker isolate, WAVs written
/// to a temp directory and played through `audioplayers`. [SpeechSilent] is
/// emitted when the queue has drained and nothing is pending; [SpeechFailed]
/// once the engine rather than the sentence is what failed — see
/// [SpeechFailures], which is the system synthesiser's rule and now this one's
/// too. Before it, one sentence a voice would not say, or one wav the player
/// refused, ended voice mode.
class SherpaSpeaker implements Speaker {
  SherpaSpeaker(this._worker) {
    _worker.messages.listen(_fromWorker);
    _player.onPlayerComplete.listen((_) => unawaited(_playNext()));
    unawaited(_open());
  }

  final Worker _worker;
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

  /// Sentences handed to the worker that have not come back as audio yet.
  var _pending = 0;

  /// See [SpeechFailures]: one sentence lost is not a broken engine.
  final _failures = SpeechFailures();

  var _closed = false;
  var _failed = false;

  /// Nothing generating, nothing queued, nothing playing — which is what there
  /// is to report as silence, and what the controller puts the microphone back
  /// on the strength of.
  bool get _silent => _pending == 0 && _queue.isEmpty && !_playing;

  Future<void> _open() async {
    // Once per session rather than once per sentence, and emptied on the way
    // in: a session killed mid-reply leaves its wavs behind, and nothing else
    // ever comes back for them.
    final speech = Directory(_speechDir);
    if (await speech.exists()) await speech.delete(recursive: true);
    await speech.create(recursive: true);
  }

  @override
  Stream<SpeechSignal> get signals => _signals.stream;

  @override
  Future<void> speak(String text) async {
    if (_closed || _failed || text.trim().isEmpty) return;
    _pending++;
    _worker.send(("speak", _generation, text));
  }

  void _fromWorker(Object? message) {
    if (_closed || _failed) return;
    switch (message) {
      case ("audio", final int generation, final Float32List samples, final int rate):
        if (generation != _generation) return;
        _pending--;
        _failures.spoke();
        unawaited(_enqueue(samples, rate));
      // The voice would not say that sentence, or said it in no samples at all.
      // Named by the batch it was queued under, so one arriving after a stop is
      // not counted against the batch that replaced it.
      case ("dropped", final int generation):
        if (generation != _generation) return;
        _dropped();
      // The engine itself: the model would not load, and nothing outstanding is
      // coming. Left counted, the session would never say it had finished.
      case ("failed", final String message):
        _fatal(message);
    }
  }

  /// The engine is gone. Everything held or playing is dead, and what arrives
  /// later belongs to an engine this side will never see.
  void _fatal(String message) {
    if (_failed || _closed) return;
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
  void _dropped() {
    if (_pending > 0) _pending--;
    if (_failures.dropped()) {
      _fatal("Speech playback keeps failing.");
    } else if (_silent) {
      _signals.add(const SpeechSilent());
    }
  }

  Future<void> _enqueue(Float32List samples, int rate) async {
    final path = p.join(_speechDir, "${DateTime.now().microsecondsSinceEpoch}.wav");
    await File(path).writeAsBytes(wavOf(samples, rate));
    _queue.add(path);
    if (!_playing) await _playNext();
  }

  Future<void> _playNext() async {
    if (_closed || _failed) return;
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
      // One wav the player would not take is one sentence rather than the
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
    _worker.close();
    await _signals.close();
  }
}

/// One isolate and the port to it. Both workers talk the same way: records in,
/// records out, `("close",)` to stop.
class Worker {
  Worker._(this._to, this._out);

  final SendPort _to;
  final StreamController<Object?> _out;

  /// Buffered rather than handed the port directly: a `ReceivePort` can only be
  /// listened to once, and the first thing through it is the worker's own send
  /// port. A single-subscription controller keeps whatever arrives between that
  /// and the session subscribing — which is where a worker that failed to load
  /// its model says so.
  Stream<Object?> get messages => _out.stream;

  static Future<Worker> spawn<T>(
      void Function((SendPort, T)) entry, T argument) async {
    final port = ReceivePort();
    final out = StreamController<Object?>();
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        return ready.complete(message);
      }
      // The worker's last word, once it has freed its models. Closing here
      // rather than in `close` is what keeps this side listening long enough
      // to know the native handles have actually gone.
      if (message case ("closed",)) return port.close();
      out.add(message);
    });
    await Isolate.spawn(entry, (port.sendPort, argument));
    return Worker._(await ready.future, out);
  }

  void send(Object? message) => _to.send(message);

  /// The close message and nothing else. `Isolate.kill` was here too, and it is
  /// a control message that pre-empts anything queued — so the worker never
  /// reached the arm that frees its recognizer, its detector or its voice, and
  /// those are native handles rather than Dart objects. Ending the loop is what
  /// releases them; the isolate then exits because its port is closed.
  void close() {
    _to.send(("close",));
    unawaited(_out.close());
  }
}

/// Everything sampled and generated at 16 kHz, which is what every recognition
/// model here was trained on. Speech comes back at whatever the speech model
/// runs at, which is its own business.
const sampleRate = 16000;

/// The listening half: voice activity, then the words. Runs until it is told to
/// close.
void _listenWorker((SendPort, (String, RecognitionModel, String)) init) async {
  final (reply, (vadPath, model, dir)) = init;
  final port = ReceivePort();
  reply.send(port.sendPort);

  sherpa.VoiceActivityDetector? vad;
  sherpa.OfflineRecognizer? recognizer;
  try {
    sherpa.initBindings();
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(model: vadPath, minSilenceDuration: 0.4),
        sampleRate: sampleRate,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    recognizer = sherpa.OfflineRecognizer(_recognizerConfig(model, dir));
  } catch (e) {
    reply.send(("failed", "$e"));
  }

  void drain(sherpa.VoiceActivityDetector vad, sherpa.OfflineRecognizer engine) {
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      final stream = engine.createStream();
      stream.acceptWaveform(samples: segment.samples, sampleRate: sampleRate);
      engine.decode(stream);
      final text = engine.getResult(stream).text.trim();
      stream.free();
      // A cough is a speech segment to a detector and nothing to a
      // conversation.
      if (text.isNotEmpty) reply.send(("heard", text));
    }
  }

  await for (final message in port) {
    if (message case ("close",)) break;
    if (vad == null || recognizer == null) continue;
    if (message case ("audio", final Float32List frame)) {
      vad.acceptWaveform(frame);
      drain(vad, recognizer);
    }
    // No more audio is coming to end the segment the detector is holding, so
    // it is ended here — the microphone closed because the sentence was over.
    else if (message case ("flush",)) {
      vad.flush();
      drain(vad, recognizer);
    }
  }
  vad?.free();
  recognizer?.free();
  port.close();
  reply.send(("closed",));
}

/// The speaking half. One sentence per message, and the samples straight back.
void _speakWorker((SendPort, (SpeechModel, String, int)) init) async {
  final (reply, (model, dir, speaker)) = init;
  final port = ReceivePort();
  reply.send(port.sendPort);

  sherpa.OfflineTts? tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(_ttsConfig(model, dir));
  } catch (e) {
    reply.send(("failed", "$e"));
  }

  await for (final message in port) {
    if (message case ("close",)) break;
    if (tts == null) continue;
    if (message case ("speak", final int generation, final String text)) {
      try {
        final audio = tts.generate(text: text, sid: speaker);
        // Always answered, even with nothing to say: the other side counts what
        // it handed over, and a sentence that came back as no samples left the
        // count standing — so the queue never drained and silence was never
        // reported, which is the microphone never opening again.
        if (audio.samples.isEmpty) {
          reply.send(("dropped", generation));
        } else {
          reply.send(("audio", generation, audio.samples, audio.sampleRate));
        }
      } catch (_) {
        // One sentence this voice will not say, rather than a voice that has
        // stopped working. Which of the two it is, is the count's to decide.
        reply.send(("dropped", generation));
      }
    }
  }
  tts?.free();
  port.close();
  reply.send(("closed",));
}

String _at(String dir, String? name) => name == null ? "" : p.join(dir, name);

sherpa.OfflineRecognizerConfig _recognizerConfig(RecognitionModel model, String dir) {
  final whisper = model.engine == VoiceEngine.whisper
      ? sherpa.OfflineWhisperModelConfig(
          encoder: _at(dir, model.encoder),
          decoder: _at(dir, model.decoder),
        )
      : const sherpa.OfflineWhisperModelConfig();
  final moonshine = model.engine == VoiceEngine.moonshine
      ? sherpa.OfflineMoonshineModelConfig(
          preprocessor: _at(dir, model.preprocessor),
          encoder: _at(dir, model.encoder),
          uncachedDecoder: _at(dir, model.uncachedDecoder),
          cachedDecoder: _at(dir, model.cachedDecoder),
        )
      : const sherpa.OfflineMoonshineModelConfig();
  final senseVoice = model.engine == VoiceEngine.senseVoice
      ? sherpa.OfflineSenseVoiceModelConfig(
          model: _at(dir, model.model),
          useInverseTextNormalization: true,
        )
      : const sherpa.OfflineSenseVoiceModelConfig();

  return sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      whisper: whisper,
      moonshine: moonshine,
      senseVoice: senseVoice,
      tokens: _at(dir, model.tokens),
      numThreads: 2,
      debug: false,
    ),
  );
}

sherpa.OfflineTtsConfig _ttsConfig(SpeechModel model, String dir) {
  final lexicon = model.lexicons
      .map((name) => p.join(dir, name))
      .where((path) => File(path).existsSync())
      .join(",");
  return sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: model.engine == VoiceEngine.vits
          ? sherpa.OfflineTtsVitsModelConfig(
              model: p.join(dir, model.model),
              tokens: p.join(dir, model.tokens),
              dataDir: _at(dir, model.dataDir),
              lexicon: lexicon,
            )
          : const sherpa.OfflineTtsVitsModelConfig(),
      kokoro: model.engine == VoiceEngine.kokoro
          ? sherpa.OfflineTtsKokoroModelConfig(
              model: p.join(dir, model.model),
              voices: _at(dir, model.voices),
              tokens: p.join(dir, model.tokens),
              dataDir: _at(dir, model.dataDir),
              dictDir: _at(dir, model.dictDir),
              lexicon: lexicon,
            )
          : const sherpa.OfflineTtsKokoroModelConfig(),
      kitten: model.engine == VoiceEngine.kitten
          ? sherpa.OfflineTtsKittenModelConfig(
              model: p.join(dir, model.model),
              voices: _at(dir, model.voices),
              tokens: p.join(dir, model.tokens),
              dataDir: _at(dir, model.dataDir),
            )
          : const sherpa.OfflineTtsKittenModelConfig(),
      numThreads: 2,
      debug: false,
    ),
    // One sentence at a time is what it is already given: the splitting is the
    // controller's, so that the first thing said starts before the reply ends.
    maxNumSenetences: 1,
  );
}
