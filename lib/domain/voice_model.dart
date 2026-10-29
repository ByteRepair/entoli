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

/// Saved under the model's own directory, named after the file it came from.
/// Recognition models are two to four of these, straight off HuggingFace —
/// which skips the fp32 copies the release tarballs carry beside the int8
/// ones, and the SenseVoice tarball is 999 MB for a 228 MB model.
class VoiceFile extends VoiceDownload {
  const VoiceFile({required super.url, required super.bytes});

  /// Derived rather than given: a name that disagreed with its URL would be a
  /// model installed under something the engine then cannot find, and every
  /// entry wrote the two out identically anyway.
  String get path => url.split("/").last;
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
/// as a file name. `androidRecognition`/`androidSpeech` are the system engines
/// — not sherpa, and routed to a platform channel rather than the onnx adapter.
enum VoiceEngine {
  whisper,
  moonshine,
  senseVoice,
  vits,
  kokoro,
  kitten,
  androidRecognition,
  androidSpeech,
  iosRecognition,
  iosSpeech,
}

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

  /// Whether this is one of the Android-system sentinels — a pick that means
  /// "use the OS engine" rather than a downloaded model. Read off [engine],
  /// which is already the one thing about a model that decides what runs it.
  bool get isNative =>
      engine == VoiceEngine.androidRecognition ||
      engine == VoiceEngine.androidSpeech ||
      engine == VoiceEngine.iosRecognition ||
      engine == VoiceEngine.iosSpeech;

  /// Which half of the model directory it installs into: one of [voiceFolders].
  String get folder;
}

/// The two halves of the model directory. Listed here beside the getter that
/// answers with them, so that a store walking both is walking what a model can
/// actually say.
const voiceFolders = ["stt", "tts"];

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
const _release = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models";

const _whisperTiny = "$_hf/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main";
const _whisperBase = "$_hf/csukuangfj/sherpa-onnx-whisper-base/resolve/main";
const _whisperSmall = "$_hf/csukuangfj/sherpa-onnx-whisper-small/resolve/main";
const _moonshineTiny = "$_hf/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/main";
const _senseVoice = "$_hf/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main";

/// What listens, roughly smallest first. Whisper tiny is the default because
/// it is the smallest thing that understands 99 languages.
const recognitionModels = <RecognitionModel>[
  RecognitionModel(
    id: "whisper-tiny",
    name: "Whisper tiny",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    note: "The smallest and fastest multilingual model.",
    encoder: "tiny-encoder.int8.onnx",
    decoder: "tiny-decoder.int8.onnx",
    tokens: "tiny-tokens.txt",
    downloads: [
      VoiceFile(url: "$_whisperTiny/tiny-encoder.int8.onnx", bytes: 12937772),
      VoiceFile(url: "$_whisperTiny/tiny-decoder.int8.onnx", bytes: 89855401),
      VoiceFile(url: "$_whisperTiny/tiny-tokens.txt", bytes: 816730),
    ],
  ),
  RecognitionModel(
    id: "moonshine-tiny-en",
    name: "Moonshine tiny",
    engine: VoiceEngine.moonshine,
    languages: "English",
    multilingual: false,
    note: "Lowest latency. Transcribes only the audio spoken, without "
        "Whisper's 30-second padding.",
    preprocessor: "preprocess.onnx",
    encoder: "encode.int8.onnx",
    uncachedDecoder: "uncached_decode.int8.onnx",
    cachedDecoder: "cached_decode.int8.onnx",
    tokens: "tokens.txt",
    downloads: [
      VoiceFile(url: "$_moonshineTiny/preprocess.onnx", bytes: 6800738),
      VoiceFile(url: "$_moonshineTiny/encode.int8.onnx", bytes: 18249187),
      VoiceFile(url: "$_moonshineTiny/uncached_decode.int8.onnx", bytes: 53216096),
      VoiceFile(url: "$_moonshineTiny/cached_decode.int8.onnx", bytes: 45264830),
      VoiceFile(url: "$_moonshineTiny/tokens.txt", bytes: 436688),
    ],
  ),
  RecognitionModel(
    id: "whisper-base",
    name: "Whisper base",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    note: "More accurate than Whisper tiny, and still fast on a phone.",
    encoder: "base-encoder.int8.onnx",
    decoder: "base-decoder.int8.onnx",
    tokens: "base-tokens.txt",
    downloads: [
      VoiceFile(url: "$_whisperBase/base-encoder.int8.onnx", bytes: 29120534),
      VoiceFile(url: "$_whisperBase/base-decoder.int8.onnx", bytes: 130672026),
      VoiceFile(url: "$_whisperBase/base-tokens.txt", bytes: 816730),
    ],
  ),
  RecognitionModel(
    id: "sense-voice",
    name: "SenseVoice small",
    engine: VoiceEngine.senseVoice,
    languages: "Chinese, English, Japanese, Korean, Cantonese",
    multilingual: true,
    note: "Several times faster than Whisper at similar accuracy, in its "
        "five languages.",
    model: "model.int8.onnx",
    tokens: "tokens.txt",
    downloads: [
      VoiceFile(url: "$_senseVoice/model.int8.onnx", bytes: 239233841),
      VoiceFile(url: "$_senseVoice/tokens.txt", bytes: 315894),
    ],
  ),
  RecognitionModel(
    id: "whisper-small",
    name: "Whisper small",
    engine: VoiceEngine.whisper,
    languages: "99 languages",
    multilingual: true,
    note: "The most accurate. Best suited to desktops; slow on a phone.",
    encoder: "small-encoder.int8.onnx",
    decoder: "small-decoder.int8.onnx",
    tokens: "small-tokens.txt",
    downloads: [
      VoiceFile(url: "$_whisperSmall/small-encoder.int8.onnx", bytes: 112442483),
      VoiceFile(url: "$_whisperSmall/small-decoder.int8.onnx", bytes: 262226114),
      VoiceFile(url: "$_whisperSmall/small-tokens.txt", bytes: 816730),
    ],
  ),
];

/// What speaks. Kokoro is the only multilingual one here — Piper covers over
/// fifty languages one model at a time, which is a language picker rather
/// than a multilingual model.
const speechModels = <SpeechModel>[
  SpeechModel(
    id: "piper-en_US-amy",
    name: "Piper (Amy)",
    engine: VoiceEngine.vits,
    languages: "English",
    multilingual: false,
    note: "A single lightweight voice.",
    model: "en_US-amy-low.onnx",
    tokens: "tokens.txt",
    dataDir: "espeak-ng-data",
    downloads: [
      VoiceArchive(url: "$_release/vits-piper-en_US-amy-low-int8.tar.bz2", bytes: 21099246),
    ],
  ),
  SpeechModel(
    id: "kitten-nano-en",
    name: "Kitten nano",
    engine: VoiceEngine.kitten,
    languages: "English",
    multilingual: false,
    note: "Eight voices in a small download.",
    model: "model.int8.onnx",
    voices: "voices.bin",
    tokens: "tokens.txt",
    dataDir: "espeak-ng-data",
    speakers: 8,
    downloads: [
      VoiceArchive(url: "$_release/kitten-nano-en-v0_8-int8.tar.bz2", bytes: 31220690),
    ],
  ),
  SpeechModel(
    id: "kokoro-multi-lang",
    name: "Kokoro",
    engine: VoiceEngine.kokoro,
    languages: "English, Chinese",
    multilingual: true,
    note: "The highest quality, and the only multilingual voice. 103 voices, "
        "three of them English.",
    model: "model.int8.onnx",
    voices: "voices.bin",
    tokens: "tokens.txt",
    lexicons: ["lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon-zh.txt"],
    dataDir: "espeak-ng-data",
    dictDir: "dict",
    speakers: 103,
    downloads: [
      VoiceArchive(url: "$_release/kokoro-int8-multi-lang-v1_1.tar.bz2", bytes: 147031220),
    ],
  ),
];

/// The Android-system sentinels: picks that mean "use the OS engine" rather
/// than a downloaded model. They are kept out of [recognitionModels] and
/// [speechModels] — the two lists the download sections draw — so there is no
/// row offering to fetch something that has nothing to fetch. The file fields
/// are empty because the engine behind these is the platform's; nothing reads
/// them, since `isNative` routes away before the sherpa config is built.
const nativeRecognition = RecognitionModel(
  id: "android-recognition",
  name: "Android system",
  engine: VoiceEngine.androidRecognition,
  languages: "System languages",
  multilingual: false,
  tokens: "",
  downloads: [],
);

const nativeSpeech = SpeechModel(
  id: "android-speech",
  name: "Android system",
  engine: VoiceEngine.androidSpeech,
  languages: "System languages",
  multilingual: false,
  model: "",
  tokens: "",
  downloads: [],
);

/// iOS's, the same idea over Apple's engines: recognition is the Speech
/// framework asked on-device and synthesis is the system's own voice, both
/// probed at startup and defaulted the same way. Nothing here is downloaded,
/// which is why iOS draws neither list.
const iosRecognition = RecognitionModel(
  id: "ios-recognition",
  name: "iOS system",
  engine: VoiceEngine.iosRecognition,
  languages: "System languages",
  multilingual: false,
  tokens: "",
  downloads: [],
);

const iosSpeech = SpeechModel(
  id: "ios-speech",
  name: "iOS system",
  engine: VoiceEngine.iosSpeech,
  languages: "System languages",
  multilingual: false,
  model: "",
  tokens: "",
  downloads: [],
);

/// Every model, either kind. The settings page draws each kind's own list; this
/// is for looking one up by the id a setting holds, which is why the sentinels
/// are in here.
const voiceCatalog = <VoiceModel>[
  ...recognitionModels,
  ...speechModels,
  nativeRecognition,
  nativeSpeech,
  iosRecognition,
  iosSpeech,
];

/// The catalog model [id] names, if it is the kind asked for. Null where it
/// names nothing, names something no longer in the catalog, or names the wrong
/// kind — a settings file can say anything.
T? voiceModelOf<T extends VoiceModel>(String? id) {
  final model = voiceModelById(id);
  return model is T ? model : null;
}

VoiceModel? voiceModelById(String? id) {
  if (id == null) return null;
  for (final model in voiceCatalog) {
    if (model.id == id) return model;
  }
  return null;
}
