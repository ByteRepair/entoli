import "../../../domain/model_info.dart";
import "../../model_role.dart";
import "../controller.dart";

/// What a model form makes: the model, the provider it is reached through,
/// and the entry it replaces where it was an edit.
typedef ModelDraft = ({
  String providerId,
  ModelInfo info,
  (String, String)? replacing,
});

/// A model models.dev does not list, described by hand for a picker of
/// [role]: the fields the catalog reads, for every frontend to ask. [model]
/// is the model being edited, on [providerId]; null adds one, on the provider
/// the picker was narrowed to where it was.
class ModelForm implements SettingForm<ModelDraft> {
  ModelForm({
    required this.role,
    required this.providers,
    this.providerId,
    this.model,
  });

  final ModelRole role;

  /// Every configured provider, by id and name.
  final List<(String, String)> providers;

  final String? providerId;
  final ModelInfo? model;

  static const _caps = [
    ("toolCall", "Tool calling"),
    ("reasoning", "Reasoning"),
    ("readsImages", "Sees images"),
    ("readsPdfs", "Reads PDFs"),
    ("makesImages", "Makes images"),
  ];

  @override
  String get title => model == null ? "Add model" : "Edit model";

  @override
  Map<String, String> get initial {
    final m = model;
    return {
      "provider": providerId ?? providers.firstOrNull?.$1 ?? "",
      "id": m?.id ?? "",
      "name": m?.name ?? "",
      "context": m?.context?.toString() ?? "",
      "output": m?.output?.toString() ?? "",
      "inputCost": m?.inputCost?.toString() ?? "",
      "outputCost": m?.outputCost?.toString() ?? "",
      "kind": switch (m) {
        ModelInfo(transcribes: true) => ModelRole.transcription.name,
        ModelInfo(speaks: true) => ModelRole.speech.name,
        ModelInfo() => ModelRole.text.name,
        null => role.voice ? role.name : ModelRole.text.name,
      },
      "caps": [
        if (m?.toolCall ?? role == ModelRole.agent) "toolCall",
        if (m?.reasoning ?? false) "reasoning",
        if (m?.readsImages ?? false) "readsImages",
        if (m?.readsPdfs ?? false) "readsPdfs",
        if (m?.makesImages ?? role == ModelRole.image) "makesImages",
      ].join(","),
    };
  }

  Set<String> _capsOf(Map<String, String> a) =>
      {...a["caps"]!.split(",")}..remove("");

  static String? _notNumber(String text, {bool decimal = false}) =>
      text.trim().isEmpty ||
          (decimal
                  ? double.tryParse(text.trim())
                  : int.tryParse(text.trim())) !=
              null
      ? null
      : "Not a number";

  @override
  List<FormFieldSpec> fields(Map<String, String> a) {
    final kind = a["kind"];
    final chat = kind == ModelRole.text.name;
    final caps = _capsOf(a);
    return [
      const FormNote(
        "For a model models.dev does not list: a fine-tune, a private "
        "deployment. Entoli trusts what you enter here, so take it from the "
        "provider's documentation.",
      ),
      FormChoice("provider", label: "Provider", [
        for (final (id, name) in providers) FormOption(id, name),
      ]),
      FormText(
        "id",
        "Model id",
        helper: "Exactly as the provider's API names it",
        focused: model == null,
      ),
      const FormText("name", "Display name (optional)"),
      FormText(
        "context",
        "Context window",
        helper: "Tokens",
        error: _notNumber(a["context"]!),
      ),
      FormText(
        "output",
        "Max output",
        helper: "Tokens",
        error: _notNumber(a["output"]!),
      ),
      FormText(
        "inputCost",
        "Input price",
        helper: r"$ per million tokens",
        error: _notNumber(a["inputCost"]!, decimal: true),
      ),
      FormText(
        "outputCost",
        "Output price",
        helper: r"$ per million tokens",
        error: _notNumber(a["outputCost"]!, decimal: true),
      ),
      FormChoice("kind", label: "It is", segmented: true, [
        FormOption(ModelRole.text.name, "Chat"),
        FormOption(ModelRole.transcription.name, "Transcribes"),
        FormOption(ModelRole.speech.name, "Speaks"),
      ]),
      if (!chat)
        FormNote(
          kind == ModelRole.transcription.name
              ? "Called at /audio/transcriptions, for voice mode's listening."
              : "Called at /audio/speech, for voice mode's speaking.",
        )
      else ...[
        FormMulti(
          "caps",
          "What it can do",
          [for (final (id, label) in _caps) FormOption(id, label)],
          error: caps.contains("toolCall")
              ? null
              : "Without tool calling it is not offered for chats.",
        ),
        if (role == ModelRole.image && !caps.contains("makesImages"))
          const FormNote(
            "It will not be offered as an image model unless it makes "
            "images.",
          ),
      ],
    ];
  }

  @override
  String? problem(Map<String, String> a) {
    if (a["provider"]!.isEmpty || a["id"]!.trim().isEmpty) return "";
    final numbers = [
      _notNumber(a["context"]!),
      _notNumber(a["output"]!),
      _notNumber(a["inputCost"]!, decimal: true),
      _notNumber(a["outputCost"]!, decimal: true),
    ];
    return numbers.any((e) => e != null) ? "" : null;
  }

  @override
  ModelDraft build(Map<String, String> a) {
    String? text(String key) => a[key]!.trim().isEmpty ? null : a[key]!.trim();
    final kind = a["kind"];
    final chat = kind == ModelRole.text.name;
    final caps = _capsOf(a);
    final before = model;
    return (
      providerId: a["provider"]!,
      info: ModelInfo(
        id: a["id"]!.trim(),
        name: text("name"),
        context: int.tryParse(text("context") ?? ""),
        output: int.tryParse(text("output") ?? ""),
        inputCost: double.tryParse(text("inputCost") ?? ""),
        outputCost: double.tryParse(text("outputCost") ?? ""),
        talks: chat,
        transcribes: kind == ModelRole.transcription.name,
        speaks: kind == ModelRole.speech.name,
        toolCall: chat && caps.contains("toolCall"),
        reasoning: chat && caps.contains("reasoning"),
        readsImages: chat && caps.contains("readsImages"),
        readsPdfs: chat && caps.contains("readsPdfs"),
        makesImages: chat && caps.contains("makesImages"),
      ),
      replacing: before == null ? null : (providerId!, before.id),
    );
  }
}
