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
}
