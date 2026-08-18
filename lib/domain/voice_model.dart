/// The voice models Entoli offers, as data: what each one is, what it costs to
/// fetch, and what its files are called once it is installed. `voice.dart` is
/// what runs them and `voice_model_store.dart` is what puts them on disk.
///
/// The catalog is a const list because there is nothing to discover: a model
/// Entoli can run is one someone wired an engine for, so a new entry is a line
/// here and a case in the adapter. Sizes are the download's, exact, so the
/// settings page can say what a row will cost before anything is fetched.
library;

/// One thing to fetch on the way to an installed model.
sealed class VoiceDownload {
  const VoiceDownload({required this.url, required this.bytes});

  final String url;

  /// What the server will send. The downloader believes `Content-Length` when
  /// it gets one; this is what the row says beforehand.
  final int bytes;
}

/// Saved as [path] under the model's own directory. Recognition models are
/// two to four of these, straight off HuggingFace — which skips the fp32 copies
/// the release tarballs carry beside the int8 ones, and the SenseVoice tarball
/// is 999 MB for a 228 MB model.
class VoiceFile extends VoiceDownload {
  const VoiceFile({required super.url, required super.bytes, required this.path});

  final String path;
}

/// A `.tar.bz2` unpacked into the model's directory. Speech models are one of
/// these because each carries `espeak-ng-data`, which is some 360 files and not
/// something to fetch one at a time.
///
/// Every entry's first path segment is dropped: these archives hold exactly one
/// top-level directory named after the model, and keeping it would put every
/// path one level deeper than the names below say.
class VoiceArchive extends VoiceDownload {
  const VoiceArchive({required super.url, required super.bytes});
}

/// Which sherpa-onnx family a model belongs to. The adapter switches on this to
/// build its config, and it is the one thing about a model that cannot be said
/// as a file name.
enum VoiceEngine { whisper, moonshine, senseVoice, vits, kokoro, kitten }

/// A model in the catalog, installed or not.
sealed class VoiceModel {
  const VoiceModel({
    required this.id,
    required this.name,
    required this.engine,
    required this.languages,
    required this.multilingual,
    required this.downloads,
    this.note,
  });

  /// Stable, and the name of the directory it installs into — so renaming one
  /// orphans what a user already downloaded.
  final String id;

  final String name;
  final VoiceEngine engine;

  /// What it can handle, as the settings row says it.
  final String languages;

  /// Whether the row wears the multilingual badge. Read off the model rather
  /// than off [languages], which is prose.
  final bool multilingual;

  /// Anything else worth knowing before downloading it — that it is really a
  /// desktop model, that it is the fastest. Null where the name and the
  /// languages say enough.
  final String? note;

  final List<VoiceDownload> downloads;

  int get bytes => downloads.fold(0, (sum, d) => sum + d.bytes);

  /// Which half of the model directory it installs into.
  String get folder;
}

/// What listens. [tokens] is every engine's; the rest are the union of what the
/// three recognition families take, and each entry fills in its own.
class RecognitionModel extends VoiceModel {
  const RecognitionModel({
    required super.id,
    required super.name,
    required super.engine,
    required super.languages,
    required super.multilingual,
    required super.downloads,
    required this.tokens,
    super.note,
    this.model,
    this.encoder,
    this.decoder,
    this.preprocessor,
    this.uncachedDecoder,
    this.cachedDecoder,
  });

  @override
  String get folder => "stt";

  final String tokens;

  /// SenseVoice: the whole model in one file.
  final String? model;

  /// Whisper and Moonshine.
  final String? encoder;

  /// Whisper.
  final String? decoder;

  /// Moonshine, which splits its decoder in two and preprocesses separately.
  final String? preprocessor;
  final String? uncachedDecoder;
  final String? cachedDecoder;
}

/// What speaks.
class SpeechModel extends VoiceModel {
  const SpeechModel({
    required super.id,
    required super.name,
    required super.engine,
    required super.languages,
    required super.multilingual,
    required super.downloads,
    required this.model,
    required this.tokens,
    super.note,
    this.voices,
    this.lexicons = const [],
    this.dataDir,
    this.dictDir,
    this.speakers = 1,
  });

  @override
  String get folder => "tts";

  final String model;
  final String tokens;

  /// Kokoro and Kitten keep their speakers in one file beside the model.
  final String? voices;

  /// Kokoro's, one per language it phonemises from a dictionary rather than
  /// through espeak.
  final List<String> lexicons;

  /// espeak-ng's data, which is most of what a speech model weighs.
  final String? dataDir;

  /// Kokoro's jieba dictionary, for segmenting Chinese.
  final String? dictDir;

  /// How many voices it has. More than one puts a voice picker beside the
  /// model in settings.
  final int speakers;
}

const _hf = "https://huggingface.co";
const _release = "https://github.com/k2-fsa/sherpa-onnx/releases/download";

/// What listens, roughly smallest first. Whisper tiny is the default because
/// it is the smallest thing that understands 99 languages.
const recognitionModels = <RecognitionModel>[
  RecognitionModel(
    id: "whisper-tiny",
    name: "Whisper tiny",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    encoder: "tiny-encoder.int8.onnx",
    decoder: "tiny-decoder.int8.onnx",
    tokens: "tiny-tokens.txt",
    downloads: [
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main/tiny-encoder.int8.onnx",
        bytes: 12937772,
        path: "tiny-encoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main/tiny-decoder.int8.onnx",
        bytes: 89855401,
        path: "tiny-decoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main/tiny-tokens.txt",
        bytes: 816730,
        path: "tiny-tokens.txt",
      ),
    ],
  ),
  RecognitionModel(
    id: "moonshine-tiny-en",
    name: "Moonshine tiny",
    engine: VoiceEngine.moonshine,
    languages: "English",
    multilingual: false,
    note: "The lowest latency: it transcribes what was said rather than "
        "padding it to Whisper's thirty seconds first.",
    preprocessor: "preprocess.onnx",
    encoder: "encode.int8.onnx",
    uncachedDecoder: "uncached_decode.int8.onnx",
    cachedDecoder: "cached_decode.int8.onnx",
    tokens: "tokens.txt",
    downloads: [
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/preprocess.onnx",
        bytes: 6800738,
        path: "preprocess.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/encode.int8.onnx",
        bytes: 18249187,
        path: "encode.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/uncached_decode.int8.onnx",
        bytes: 53216096,
        path: "uncached_decode.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/cached_decode.int8.onnx",
        bytes: 45264830,
        path: "cached_decode.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main/tokens.txt",
        bytes: 436688,
        path: "tokens.txt",
      ),
    ],
  ),
  RecognitionModel(
    id: "whisper-base",
    name: "Whisper base",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    note: "Noticeably better than tiny, and still comfortable on a phone.",
    encoder: "base-encoder.int8.onnx",
    decoder: "base-decoder.int8.onnx",
    tokens: "base-tokens.txt",
    downloads: [
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-encoder.int8.onnx",
        bytes: 29120534,
        path: "base-encoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-decoder.int8.onnx",
        bytes: 130672026,
        path: "base-decoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-base/resolve/main/base-tokens.txt",
        bytes: 816730,
        path: "base-tokens.txt",
      ),
    ],
  ),
  RecognitionModel(
    id: "sense-voice",
    name: "SenseVoice small",
    engine: VoiceEngine.senseVoice,
    languages: "Chinese, English, Japanese, Korean, Cantonese",
    multilingual: true,
    note: "One forward pass rather than a token loop, so it is several times "
        "faster than a Whisper of its accuracy — on its five languages.",
    model: "model.int8.onnx",
    tokens: "tokens.txt",
    downloads: [
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
        bytes: 239233841,
        path: "model.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
        bytes: 315894,
        path: "tokens.txt",
      ),
    ],
  ),
  RecognitionModel(
    id: "whisper-small",
    name: "Whisper small",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    note: "The accurate one, and a desktop's: a phone will run it, slowly.",
    encoder: "small-encoder.int8.onnx",
    decoder: "small-decoder.int8.onnx",
    tokens: "small-tokens.txt",
    downloads: [
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-encoder.int8.onnx",
        bytes: 112442483,
        path: "small-encoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-decoder.int8.onnx",
        bytes: 262226114,
        path: "small-decoder.int8.onnx",
      ),
      VoiceFile(
        url: "$_hf/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-tokens.txt",
        bytes: 816730,
        path: "small-tokens.txt",
      ),
    ],
  ),
];

/// What speaks. Kokoro is the only multilingual one there is at this size —
/// Piper covers thirty languages one model at a time, which is a language
/// picker rather than a multilingual model, and everything genuinely
/// multilingual beyond it is far too big for a phone.
const speechModels = <SpeechModel>[
  SpeechModel(
    id: "piper-en_US-amy",
    name: "Piper (Amy)",
    engine: VoiceEngine.vits,
    languages: "English",
    multilingual: false,
    model: "en_US-amy-low.onnx",
    tokens: "tokens.txt",
    dataDir: "espeak-ng-data",
    downloads: [
      VoiceArchive(
        url: "$_release/tts-models/vits-piper-en_US-amy-low-int8.tar.bz2",
        bytes: 21099246,
      ),
    ],
  ),
  SpeechModel(
    id: "kitten-nano-en",
    name: "Kitten nano",
    engine: VoiceEngine.kitten,
    languages: "English",
    multilingual: false,
    note: "Eight voices in thirty megabytes.",
    model: "model.int8.onnx",
    voices: "voices.bin",
    tokens: "tokens.txt",
    dataDir: "espeak-ng-data",
    speakers: 8,
    downloads: [
      VoiceArchive(
        url: "$_release/tts-models/kitten-nano-en-v0_8-int8.tar.bz2",
        bytes: 31220690,
      ),
    ],
  ),
  SpeechModel(
    id: "kokoro-multi-lang",
    name: "Kokoro",
    engine: VoiceEngine.kokoro,
    languages: "English, Chinese",
    multilingual: true,
    note: "The best of these by some way, and the only one that speaks more "
        "than one language.",
    model: "model.int8.onnx",
    voices: "voices.bin",
    tokens: "tokens.txt",
    lexicons: ["lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon-zh.txt"],
    dataDir: "espeak-ng-data",
    dictDir: "dict",
    speakers: 103,
    downloads: [
      VoiceArchive(
        url: "$_release/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2",
        bytes: 147031220,
      ),
    ],
  ),
];

/// Every model, either kind. The settings page draws each kind's own list; this
/// is for looking one up by the id a setting holds.
const voiceCatalog = <VoiceModel>[...recognitionModels, ...speechModels];

/// The two models voice mode would use, as a settings file names them. Null
/// where it names nothing, names something no longer in the catalog, or names
/// the wrong kind — it is a file, and can say anything.
({RecognitionModel? recognition, SpeechModel? speech}) voiceChoice(
  String? recognitionId,
  String? speechId,
) =>
    (
      recognition: switch (voiceModelById(recognitionId)) {
        final RecognitionModel model => model,
        _ => null,
      },
      speech: switch (voiceModelById(speechId)) {
        final SpeechModel model => model,
        _ => null,
      },
    );

VoiceModel? voiceModelById(String? id) {
  if (id == null) return null;
  for (final model in voiceCatalog) {
    if (model.id == id) return model;
  }
  return null;
}
