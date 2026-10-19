/// What the app knows of one model: the fields of models.dev it reads, in
/// models.dev's own JSON shape, which is also how a model the user adds by
/// hand is stored.
class ModelInfo {
  const ModelInfo({
    required this.id,
    this.name,
    this.readsImages = false,
    this.makesImages = false,
    this.context,
    this.output,
    this.reasoning = false,
    this.toolCall = false,
    this.talks = true,
    this.inputCost,
    this.outputCost,
  });

  factory ModelInfo.fromJson(String id, Map json) {
    final modalities = json["modalities"];
    // A side not named is text, the ordinary case.
    bool has(String side, String kind) =>
        (modalities is Map ? modalities[side] as List? : null)?.contains(kind) ??
        kind == "text";
    final limit = json["limit"] is Map ? json["limit"] as Map : const {};
    final cost = json["cost"] is Map ? json["cost"] as Map : const {};
    // models.dev writes 0 for a model with no window to speak of (an image
    // model), which is no answer rather than a window of nothing.
    int? positive(Object? n) => n is num && n > 0 ? n.toInt() : null;
    double? price(Object? n) => n is num ? n.toDouble() : null;
    return ModelInfo(
      id: id,
      name: json["name"] is String ? json["name"] as String : null,
      readsImages: has("input", "image"),
      makesImages: has("output", "image"),
      talks: has("input", "text") && has("output", "text"),
      context: positive(limit["context"]),
      output: positive(limit["output"]),
      reasoning: json["reasoning"] == true,
      toolCall: json["tool_call"] == true,
      inputCost: price(cost["input"]),
      outputCost: price(cost["output"]),
    );
  }

  final String id;
  final String? name;

  /// Whether an image may be sent to it. A listed model that does not say is
  /// false, since an image a model cannot take fails the whole request.
  final bool readsImages;
  final bool makesImages;

  /// The context window in tokens, null where unknown — read as
  /// `AppSettings.totalContext`, the app-wide guess.
  final int? context;
  final int? output;
  final bool reasoning;
  final bool toolCall;

  /// Takes text in and gives text out: a chat model, rather than a speech,
  /// transcription or image-only one.
  final bool talks;

  /// US dollars per million tokens.
  final double? inputCost;
  final double? outputCost;

  String get displayName => name ?? id;

  /// What the agent needs of a model that answers turns: it works through
  /// tools. The background roles — title, classifier, memory — need only
  /// [talks].
  bool get answersTurns => talks && toolCall;

  Map<String, dynamic> toJson() => {
        if (name != null) "name": name,
        "reasoning": reasoning,
        "tool_call": toolCall,
        "modalities": {
          "input": [if (talks) "text", if (readsImages) "image"],
          "output": [if (talks) "text", if (makesImages) "image"],
        },
        "limit": {"context": ?context, "output": ?output},
        if (inputCost != null || outputCost != null)
          "cost": {"input": ?inputCost, "output": ?outputCost},
      };
}
