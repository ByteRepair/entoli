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

import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "wav.dart";

/// Listening and speaking through sherpa-onnx. Two worker isolates rather than
/// one, which is the design rather than an optimisation — see "Hearing and
/// speaking" in CLAUDE.md for why the microphone must not queue behind a
/// sentence being generated.
class SherpaVoice extends Voice {
  SherpaVoice(this._store, this._cacheDir);

  final VoiceModelStore _store;

  /// Where the Silero model is unpacked to. The bundled asset cannot be given
  /// to sherpa as bytes: every model it takes, it takes as a path.
  final String _cacheDir;

  /// Where a spoken sentence is written on its way to the player. Genuinely
  /// disposable, so the system's own temporary directory rather than
  /// [_cacheDir] — which on Android is deliberately the *non*-evictable one, so
  /// that a downloaded model is never thrown away, and is the wrong home for a
  /// WAV that lives for a sentence.
  static String get scratchDir => p.join(Directory.systemTemp.path, "entoli-speech");

  static const _vadAsset = "assets/models/silero_vad.onnx";

  @override
  Future<VoiceSession> start({
    required RecognitionModel recognition,
    required SpeechModel speech,
    int speaker = 0,
  }) async {
    final listenDir = await _store.directoryOf(recognition);
    final speakDir = await _store.directoryOf(speech);
    if (listenDir == null) throw StateError("${recognition.name} is not downloaded.");
    if (speakDir == null) throw StateError("${speech.name} is not downloaded.");

    final recorder = AudioRecorder();
    if (!await recorder.hasPermission()) {
      recorder.dispose();
      throw StateError("Entoli was not allowed to use the microphone.");
    }

    final vad = await _vadPath();
    final listener = await _Worker.spawn(_listenWorker, (vad, recognition, listenDir));
    final speaker0 = await _Worker.spawn(_speakWorker, (speech, speakDir, speaker));
    return _SherpaSession(recorder, listener, speaker0, scratchDir);
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

/// The microphone, the two workers, and whatever is queued to be said.
class _SherpaSession implements VoiceSession {
  _SherpaSession(this._recorder, this._listener, this._speaker, this._speechDir) {
    _listener.messages.listen(_fromListener);
    _speaker.messages.listen(_fromSpeaker);
    _player.onPlayerComplete.listen((_) => _playNext());
    unawaited(_open());
  }

  final AudioRecorder _recorder;
  final _Worker _listener;
  final _Worker _speaker;
  final String _speechDir;
  final _player = AudioPlayer();

  final _events = StreamController<VoiceEvent>.broadcast();
  final _levelOf = ValueNotifier(0.0);

  StreamSubscription<Uint8List>? _mic;

  /// Whole VAD windows only: what the microphone hands over is however much it
  /// had, and the detector wants 512 samples at a time.
  var _window = Float32List(_windowSize);
  var _filled = 0;

  /// Generated audio waiting its turn, and what is playing now. Speech is
  /// generated a sentence ahead of being heard, so there is always a queue.
  final _queue = <String>[];
  var _playing = false;

  /// Bumped by [stopSpeaking]. Audio generated before it is dropped rather than
  /// played into a silence the user asked for.
  var _generation = 0;

  var _closed = false;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  ValueListenable<double> get level => _levelOf;

  Future<void> _open() async {
    // Once per session rather than once per sentence, and emptied on the way
    // in: a session killed mid-reply leaves its wavs behind, and nothing else
    // ever comes back for them.
    final speech = Directory(_speechDir);
    if (await speech.exists()) await speech.delete(recursive: true);
    await speech.create(recursive: true);
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // The reply comes out of the same device the microphone is on, so
        // without this the model hears itself and every sentence is a barge-in.
        echoCancel: true,
        noiseSuppress: true,
      ));
      _mic = stream.listen(_onAudio, onError: (Object e) => _fail("$e"));
    } catch (e) {
      _fail("$e");
    }
  }

  void _onAudio(Uint8List bytes) {
    if (_closed) return;
    final samples = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
    var sum = 0.0;
    for (final sample in samples) {
      final value = sample / 32768.0;
      sum += value * value;
      _window[_filled++] = value;
      if (_filled < _windowSize) continue;
      // Handed over rather than copied: `send` copies for us, so the buffer is
      // the worker's now and this side starts a fresh one.
      _listener.send(("audio", _window));
      _window = Float32List(_windowSize);
      _filled = 0;
    }
    // Root mean square, and it decays rather than tracking: the circle should
    // breathe with a voice rather than flicker with every frame's peak.
    final loudness = math.sqrt(sum / math.max(1, samples.length));
    final level = math.max(loudness * 3, _levelOf.value * 0.8).clamp(0.0, 1.0);
    // Snapped to zero rather than decaying towards it forever: a geometric
    // decay never reaches its floor, so a silent room would go on notifying
    // thirty times a second, and every one of those repaints the circle.
    _levelOf.value = level < 0.005 ? 0 : level;
  }

  void _fromListener(Object? message) {
    switch (message) {
      case ("heard", final String text):
        _events.add(VoiceHeard(text));
      case ("detected",):
        // Talking over the reply. The speech stops here rather than in the
        // controller, so the moment the user starts is the moment it goes
        // quiet — whatever the controller then decides about the turn.
        if (_playing || _queue.isNotEmpty) {
          unawaited(stopSpeaking());
          _events.add(const VoiceInterrupted());
        }
      case ("failed", final String message):
        _fail(message);
    }
  }

  void _fromSpeaker(Object? message) {
    switch (message) {
      case ("audio", final int generation, final Float32List samples, final int rate):
        if (generation != _generation || _closed) return;
        unawaited(_enqueue(samples, rate));
      case ("failed", final String message):
        _fail(message);
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_closed || text.trim().isEmpty) return;
    _speaker.send(("speak", _generation, text));
  }

  Future<void> _enqueue(Float32List samples, int rate) async {
    final path =
        p.join(_speechDir, "${DateTime.now().microsecondsSinceEpoch}.wav");
    await File(path).writeAsBytes(wavOf(samples, rate));
    _queue.add(path);
    if (!_playing) await _playNext();
  }

  Future<void> _playNext() async {
    if (_closed) return;
    if (_queue.isEmpty) {
      if (_playing) {
        _playing = false;
        _events.add(const VoiceFellSilent());
      }
      return;
    }
    final next = _queue.removeAt(0);
    _playing = true;
    try {
      await _player.play(DeviceFileSource(next));
    } catch (e) {
      _playing = false;
      _fail("$e");
    }
    unawaited(_discard(next));
  }

  @override
  Future<void> stopSpeaking() async {
    // Before the stop, so audio already generated is dropped rather than
    // arriving into the silence and starting the queue up again.
    _generation++;
    // Deleted rather than dropped: only `_playNext` removes a file it played,
    // so a barge-in used to leave every unsaid sentence in the cache with
    // nothing that would ever come back for it.
    for (final path in _queue) {
      unawaited(_discard(path));
    }
    _queue.clear();
    _playing = false;
    await _player.stop();
  }

  Future<void> _discard(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _fail(String message) {
    if (!_closed) _events.add(VoiceFailed(message));
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _mic?.cancel();
    await _recorder.stop();
    _recorder.dispose();
    await _player.stop();
    await _player.dispose();
    _listener.close();
    _speaker.close();
    await _events.close();
    _levelOf.dispose();
  }

  /// Silero's window, and so the size of every frame handed to the worker.
  static const _windowSize = 512;
}

/// One isolate and the port to it. Both workers talk the same way: records in,
/// records out, `("close",)` to stop.
class _Worker {
  _Worker._(this._to, this._out);

  final SendPort _to;
  final StreamController<Object?> _out;

  /// Buffered rather than handed the port directly: a `ReceivePort` can only be
  /// listened to once, and the first thing through it is the worker's own send
  /// port. A single-subscription controller keeps whatever arrives between that
  /// and the session subscribing — which is where a worker that failed to load
  /// its model says so.
  Stream<Object?> get messages => _out.stream;

  static Future<_Worker> spawn<T>(
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
    return _Worker._(await ready.future, out);
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

  var wasSpeaking = false;
  await for (final message in port) {
    if (message case ("close",)) break;
    if (vad == null || recognizer == null) continue;
    if (message case ("audio", final Float32List frame)) {
      vad.acceptWaveform(frame);
      final speaking = vad.isDetected();
      if (speaking && !wasSpeaking) reply.send(("detected",));
      wasSpeaking = speaking;

      while (!vad.isEmpty()) {
        final segment = vad.front();
        vad.pop();
        final stream = recognizer.createStream();
        stream.acceptWaveform(samples: segment.samples, sampleRate: sampleRate);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text.trim();
        stream.free();
        // A cough is a speech segment to a detector and nothing to a
        // conversation.
        if (text.isNotEmpty) reply.send(("heard", text));
      }
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
        if (audio.samples.isNotEmpty) {
          reply.send(("audio", generation, audio.samples, audio.sampleRate));
        }
      } catch (e) {
        reply.send(("failed", "$e"));
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
