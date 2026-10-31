import "dart:async";
import "dart:io";
import "dart:isolate";
import "dart:math" as math;
import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;
import "package:record/record.dart";
import "package:sherpa_onnx/sherpa_onnx.dart" as sherpa;

import "../../domain/loudness.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model.dart";
import "../../domain/voice_model_store.dart";
import "../model_host/model_host.dart";
import "../model_host/worker.dart";
import "pcm.dart";
import "played_speaker.dart";
import "remote_speaker.dart";
import "voice_strategies.dart";
import "wav.dart";

/// Listening and speaking through sherpa-onnx: the desktops' answer, and the
/// fallback on an Android whose system recognizer cannot be used — see
/// `AndroidVoice`. `start` builds a [SherpaListener] and a [SherpaSpeaker] and
/// hands them to a [ComposedVoiceSession], which forwards both halves' events.
/// See "Hearing and speaking" in AGENTS.md for the two-worker design.
class SherpaVoice extends Voice {
  SherpaVoice(this._store, this._cacheDir, this._host);

  final VoiceModelStore _store;

  /// Where the two workers run: the model host on macOS, this process
  /// elsewhere.
  final ModelHost _host;

  /// Where the Silero model is unpacked to. The bundled asset cannot be given
  /// to sherpa as bytes: every model it takes, it takes as a path.
  final String _cacheDir;

  static const _vadAsset = "assets/models/silero_vad.onnx";

  @override
  Future<VoiceSession> start({
    Hearing? hearing,
    required Speaking speaking,
    int speaker = 0,
    String? language,
  }) async => composeSession(
    hearing == null ? null : await sherpaListener(hearing),
    switch (speaking) {
      SpeakOnDevice(:final model) => sherpaSpeaker(model, speaker),
      SpeakThrough(:final synthesize) => Future.value(
        RemoteSpeaker(synthesize),
      ),
    },
  );

  /// The sherpa listening half; `AndroidVoice` uses it too. A provider's
  /// model listens through the same microphone and Silero, with each
  /// utterance sent away whole rather than decoded here. Everything that can
  /// refuse runs before the worker is spawned, which would otherwise load a
  /// hundred megabytes only to free them.
  Future<SherpaListener> sherpaListener(Hearing hearing) async {
    final model = <Object?>[];
    if (hearing case HearOnDevice(model: final recognition)) {
      final dir = await _store.directoryOf(recognition);
      if (dir == null) {
        throw StateError("${recognition.name} is not downloaded.");
      }
      model.addAll([recognition.id, dir]);
    }
    final recorder = await openMicrophone();
    final vad = await _vadPath();
    final worker = await _host.spawn(listenWorker, [vad, ...model]);
    return SherpaListener(
      recorder,
      worker,
      transcribe: hearing is HearThrough ? hearing.transcribe : null,
    );
  }

  /// The sherpa speaking half for one speech model, for the same reason as
  /// [sherpaListener].
  Future<SherpaSpeaker> sherpaSpeaker(SpeechModel speech, int speaker) async {
    final speakDir = await _store.directoryOf(speech);
    if (speakDir == null) throw StateError("${speech.name} is not downloaded.");
    final worker = await _host.spawn(speakWorker, [
      speech.id,
      speakDir,
      speaker,
    ]);
    return SherpaSpeaker(worker);
  }

  /// The Silero model on disk, copied out of the bundle the first time: every
  /// model sherpa takes, it takes as a path.
  Future<String> _vadPath() async {
    final path = p.join(_cacheDir, "silero_vad.onnx");
    final file = File(path);
    if (!file.existsSync()) {
      final data = await rootBundle.load(_vadAsset);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return path;
  }
}

/// The sherpa listening half: a microphone, Silero VAD, and an offline
/// recognizer, in one worker isolate. The gate, the level and the event stream
/// are [MicrophoneListener]'s; what is here is the recorder and the worker.
///
/// Silero says whether it is a voice, not whose, so this feeds the gate one
/// [decibels] reading per 32 ms detector window.
class SherpaListener extends MicrophoneListener {
  SherpaListener(this._recorder, this._worker, {this._transcribe})
    : super(LoudnessGate()) {
    // An error is the worker ended under it — its process gone, or it never
    // started — which is a listener as broken as one whose model would not
    // load.
    _worker.messages.listen(_fromWorker, onError: (Object e) => fail("$e"));
  }

  final AudioRecorder _recorder;
  final Worker _worker;

  /// Where the worker holds no recognizer and sends utterances back whole.
  final Transcribe? _transcribe;

  /// The last utterance sent off, so the next waits for it: one at a time is
  /// what keeps them in the order they were said.
  Future<void> _sent = Future.value();

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
      if (finish) _worker.send(["flush"]);
      await _mic?.cancel();
      _mic = null;
      await _recorder.stop();
      _filled = 0;
      _square = 0;
      return;
    }
    try {
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          // The reply comes out of the same device the microphone is on. The
          // microphone is shut while one is being read out, so this is belt and
          // braces rather than the thing keeping the model from hearing itself.
          // Not on macOS: there it is Apple's voice processing, whose input is
          // several channels that `record` converts to mono as pure silence.
          echoCancel: !Platform.isMacOS,
          noiseSuppress: true,
        ),
      );
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
      _worker.send(["audio", _window]);
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
      case ["heard", final String text]:
        heard(text);
      case ["segment", final Uint8List wav]:
        _send(wav);
      case ["failed", final String message]:
        fail(message);
    }
  }

  /// Only a worker spawned with no model sends segments, and only for a
  /// listener given [_transcribe].
  void _send(Uint8List wav) {
    if (closed) return;
    // Judged now, against the room it was said in: by the time the provider
    // answers, more of the room has been measured. Refused here, a sentence
    // the gate would drop is not paid for.
    if (!gate.spoken()) {
      return voiceFailed("utterance refused: too quiet for this room");
    }
    _sent = _sent.then((_) async {
      if (closed) return;
      try {
        heard(await _transcribe!(wav), judged: true);
      } catch (e) {
        fail("Transcription failed: $e");
      }
    });
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

/// The sherpa speaking half: an offline TTS in one worker isolate, its
/// samples played by [PlayingSpeaker].
class SherpaSpeaker extends PlayingSpeaker {
  SherpaSpeaker(this._worker) {
    // The worker ended under it: its process gone, or it never started.
    _worker.messages.listen(_fromWorker, onError: (Object e) => broke("$e"));
  }

  final Worker _worker;

  @override
  Future<void> speak(String text) async {
    if (!usable || text.trim().isEmpty) return;
    _worker.send(["speak", queued(), text]);
  }

  void _fromWorker(Object? message) {
    switch (message) {
      case ["audio", final int generation, final Uint8List wav]:
        generated(generation, wav);
      case ["dropped", final int generation]:
        lost(generation);
      // The model would not load.
      case ["failed", final String message]:
        broke(message);
    }
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    _worker.close();
  }
}

/// Everything sampled and generated at 16 kHz, which is what every recognition
/// model here was trained on. Speech comes back at whatever the speech model
/// runs at, which is its own business.
const sampleRate = 16000;

/// The listening half: voice activity, then the words. Runs until it is told to
/// close. With no model, each utterance is sent back as samples for a provider
/// to transcribe. Its argument is Silero's path, then the recognition model's
/// id and directory where there is one.
const listenWorker = WorkerKind("sherpa-listen", _listenWorker);

/// The speaking half: a speech model's id, its directory and the speaker.
const speakWorker = WorkerKind("sherpa-speak", _speakWorker);

/// Every worker this file runs, for the model host to start by name.
const sherpaWorkers = [listenWorker, speakWorker];

void _listenWorker((SendPort, List<Object?>) init) async {
  final (reply, argument) = init;
  final vadPath = argument[0] as String;
  final model = switch (argument) {
    [_, final String id, final String dir] => (
      recognitionModels.firstWhere((m) => m.id == id),
      dir,
    ),
    _ => null,
  };
  final port = ReceivePort();
  reply.send(port.sendPort);

  sherpa.VoiceActivityDetector? vad;
  sherpa.OfflineRecognizer? recognizer;
  try {
    sherpa.initBindings();
    // Before the detector, so a model that will not load leaves it null and
    // the loop below idle.
    if (model case (final model, final dir)) {
      recognizer = sherpa.OfflineRecognizer(_recognizerConfig(model, dir));
    }
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          minSilenceDuration: 0.4,
        ),
        sampleRate: sampleRate,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
  } catch (e) {
    reply.send(["failed", "$e"]);
  }

  void drain(
    sherpa.VoiceActivityDetector vad,
    sherpa.OfflineRecognizer? engine,
  ) {
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      if (engine == null) {
        reply.send(["segment", wavOf(segment.samples, sampleRate)]);
        continue;
      }
      final stream = engine.createStream();
      stream.acceptWaveform(samples: segment.samples, sampleRate: sampleRate);
      engine.decode(stream);
      final text = engine.getResult(stream).text.trim();
      stream.free();
      // A cough is a speech segment to a detector and nothing to a
      // conversation.
      if (text.isNotEmpty) reply.send(["heard", text]);
    }
  }

  await for (final message in port) {
    if (message case ["close"]) break;
    if (vad == null) continue;
    if (message case ["audio", final Float32List frame]) {
      vad.acceptWaveform(frame);
      drain(vad, recognizer);
    }
    // No more audio is coming to end the segment the detector is holding, so
    // it is ended here — the microphone closed because the sentence was over.
    else if (message case ["flush"]) {
      vad.flush();
      drain(vad, recognizer);
    }
  }
  vad?.free();
  recognizer?.free();
  port.close();
  reply.send(["closed"]);
}

/// One sentence per message, and the samples straight back.
void _speakWorker((SendPort, List<Object?>) init) async {
  final (reply, argument) = init;
  final model = speechModels.firstWhere((m) => m.id == argument[0]);
  final dir = argument[1] as String;
  final speaker = argument[2] as int;
  final port = ReceivePort();
  reply.send(port.sendPort);

  sherpa.OfflineTts? tts;
  try {
    sherpa.initBindings();
    tts = sherpa.OfflineTts(_ttsConfig(model, dir));
  } catch (e) {
    reply.send(["failed", "$e"]);
  }

  await for (final message in port) {
    if (message case ["close"]) break;
    if (tts == null) continue;
    if (message case ["speak", final int generation, final String text]) {
      try {
        final audio = tts.generate(text: text, sid: speaker);
        // Always answered, even with nothing to say: the other side counts what
        // it handed over, and a sentence that came back as no samples left the
        // count standing — so the queue never drained and silence was never
        // reported, which is the microphone never opening again.
        if (audio.samples.isEmpty) {
          reply.send(["dropped", generation]);
        } else {
          // Encoded here rather than on the UI isolate.
          reply.send([
            "audio",
            generation,
            wavOf(audio.samples, audio.sampleRate),
          ]);
        }
      } catch (_) {
        // One sentence this voice will not say, rather than a voice that has
        // stopped working. Which of the two it is, is the count's to decide.
        reply.send(["dropped", generation]);
      }
    }
  }
  tts?.free();
  port.close();
  reply.send(["closed"]);
}

String _at(String dir, String? name) => name == null ? "" : p.join(dir, name);

sherpa.OfflineRecognizerConfig _recognizerConfig(
  RecognitionModel model,
  String dir,
) {
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
