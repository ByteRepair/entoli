/// How hard the image model works on one image. Named as OpenAI's `quality`
/// is; [auto] sends nothing and leaves the provider's own default.
enum ImageQuality { auto, low, medium, high }

/// What each [ImageQuality] is called on a slider.
const imageQualityLabels = {
  ImageQuality.auto: "Default",
  ImageQuality.low: "Low",
  ImageQuality.medium: "Medium",
  ImageQuality.high: "High",
};

/// How long a reasoning model thinks before it answers, sent as the OpenAI
/// shape's `reasoning_effort` and mapped onto a thinking budget for
/// Anthropic. [auto] sends nothing and leaves the model's own default.
enum ReasoningEffort {
  auto,
  low,
  medium,
  high;

  /// What the request carries, or null for nothing.
  String? get wire => this == auto ? null : name;
}

/// What each [ReasoningEffort] is called on a slider.
const reasoningEffortLabels = {
  ReasoningEffort.auto: "Default",
  ReasoningEffort.low: "Low",
  ReasoningEffort.medium: "Medium",
  ReasoningEffort.high: "High",
};
