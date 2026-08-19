import "package:agent_chat/domain/voice_model.dart";
import "package:flutter_test/flutter_test.dart";

/// The catalog is data, so what is worth pinning is that the data holds
/// together: an entry naming a file nothing fetches is voice mode failing to
/// start after a hundred-megabyte download.

/// The models the sherpa adapter runs, which is what every invariant below is
/// about. Named rather than filtered out of [voiceCatalog] one test at a time:
/// the system sentinels have no files and no download, so a rule stated over
/// them would have to carry an exception, and a rule with an exception in it is
/// harder to read than the two lists it is really about.
const sherpaModels = <VoiceModel>[...recognitionModels, ...speechModels];

void main() {
  test("every id is unique — it is the directory a model installs into", () {
    final ids = voiceCatalog.map((m) => m.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test("every model has something to fetch, and says what it weighs", () {
    for (final model in sherpaModels) {
      expect(model.downloads, isNotEmpty, reason: model.id);
      expect(model.bytes, greaterThan(0), reason: model.id);
      for (final download in model.downloads) {
        expect(download.bytes, greaterThan(0), reason: "${model.id} ${download.url}");
        expect(Uri.tryParse(download.url)?.isScheme("https"), isTrue, reason: model.id);
      }
    }
  });

  test("a file the engine needs is a file something downloads", () {
    for (final model in sherpaModels) {
      // An archive brings a directory with it, so its contents are its own
      // business; individual files have to be named by a download.
      if (model.downloads.any((d) => d is VoiceArchive)) continue;
      final fetched = {
        for (final download in model.downloads)
          if (download is VoiceFile) download.path,
      };
      for (final needed in _needs(model)) {
        expect(fetched, contains(needed), reason: model.id);
      }
    }
  });

  test("each engine gets the files it takes", () {
    for (final model in sherpaModels) {
      switch (model) {
        case RecognitionModel(engine: VoiceEngine.whisper):
          expect(model.encoder, isNotNull, reason: model.id);
          expect(model.decoder, isNotNull, reason: model.id);
        case RecognitionModel(engine: VoiceEngine.moonshine):
          expect(model.preprocessor, isNotNull, reason: model.id);
          expect(model.uncachedDecoder, isNotNull, reason: model.id);
          expect(model.cachedDecoder, isNotNull, reason: model.id);
        case RecognitionModel(engine: VoiceEngine.senseVoice):
          expect(model.model, isNotNull, reason: model.id);
        case SpeechModel(engine: VoiceEngine.kokoro || VoiceEngine.kitten):
          expect(model.voices, isNotNull, reason: model.id);
        default:
          break;
      }
    }
  });

  test("recognition models install under stt and speech models under tts", () {
    for (final model in recognitionModels) {
      expect(model.folder, "stt");
    }
    for (final model in speechModels) {
      expect(model.folder, "tts");
    }
  });

  test("a multilingual model is the only kind that wears the badge", () {
    expect(voiceCatalog.where((m) => m.multilingual).map((m) => m.id), [
      "whisper-tiny",
      "whisper-base",
      "sense-voice",
      "whisper-small",
      "kokoro-multi-lang",
    ]);
  });

  test("looking one up by id finds it, and an unknown one finds nothing", () {
    expect(voiceModelById("whisper-tiny")?.name, "Whisper tiny");
    expect(voiceModelById("nothing-like-this"), isNull);
    expect(voiceModelById(null), isNull);
  });
}

Iterable<String> _needs(VoiceModel model) => switch (model) {
      RecognitionModel() => [
          model.tokens,
          ?model.model,
          ?model.encoder,
          ?model.decoder,
          ?model.preprocessor,
          ?model.uncachedDecoder,
          ?model.cachedDecoder,
        ],
      SpeechModel() => [model.model, model.tokens, ?model.voices],
    };
