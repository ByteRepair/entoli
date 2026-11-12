import "../data/builtin/llm/hosted_models.dart" show ImageModel;
import "../domain/local_model.dart" show isTitleOnlyModel;
import "../domain/model_capability.dart";

/// What a picker's model is for, which decides what it is offered.
enum ModelRole {
  /// Answers turns, which the agent does through tools: only models that call
  /// them.
  agent,

  /// A background completion — a classifier verdict, a memory pass — which
  /// needs only text in and text out.
  text,

  /// A chat's title: [text], plus the models that answer nothing else
  /// ([isTitleOnlyModel]).
  title,

  /// Answers `image_generation`: only models that make images.
  image,

  /// Voice mode's ears through a provider: only models that transcribe.
  transcription,

  /// Voice mode's voice through a provider: only models that speak.
  speech;

  bool offers(Model m) => switch (this) {
    agent => m is ChatModel && m.info.answersTurns,
    text || title => m is ChatModel,
    image => m is ImageModel,
    transcription => m is TranscriptionModel,
    speech => m is SynthesisModel,
  };

  /// Whether its models are chat models: the ones only an endpoint's own list
  /// names are offered, being taken for chat models since nothing says
  /// otherwise, and whether one sees images is worth filtering on.
  bool get chat => this == agent || this == text || this == title;

  bool get voice => this == transcription || this == speech;

  /// What the picker's page is called, and what its empty list says.
  String get noun => switch (this) {
    image => "image model",
    transcription => "transcription model",
    speech => "speech model",
    _ => "model",
  };

  /// The article [noun] takes: "an image model", "a model".
  String get article => "aeiou".contains(noun[0]) ? "an" : "a";

  /// What a picker with no models at all says, for a role that is most often
  /// a provider without such models rather than a model missing from a list.
  String? get emptyNote => switch (this) {
    image =>
      "None of your providers makes images. OpenAI and OpenRouter do: add "
          "one in Settings > Providers.",
    transcription =>
      "Nothing here can listen yet. Download a model in Settings > "
          "On-device, or add a provider with one: Groq has Whisper, and "
          "OpenAI's whisper-1 can be added by hand.",
    speech =>
      "Nothing here can speak yet. Download a model in Settings > "
          "On-device, or add a provider with one: Groq and Google have them, "
          "and OpenAI's tts-1 can be added by hand.",
    _ => null,
  };
}
