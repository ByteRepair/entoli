import "../core/formatting.dart" show nonBlank;
import "../domain/llm_provider.dart";
import "../domain/model_info.dart";
import "../providers.dart";
import "model_role.dart";
import "reader.dart";

/// What a model added by hand can be said to do.
enum ModelCap { toolCall, reasoning, readsImages, readsPdfs, makesImages }

/// A model models.dev does not list, described by hand for a picker of
/// [role]: the fields the catalog reads. [model] is the one being edited,
/// on [providerId]; null adds one, on the provider the picker was narrowed
/// to where it was.
class CustomModelDraft {
  CustomModelDraft({
    required this.role,
    required this.providers,
    String? providerId,
    this.model,
  }) : _editedOn = providerId,
       provider = providerId ?? providers.firstOrNull?.$1 ?? "",
       id = model?.id ?? "",
       name = model?.name ?? "",
       context = model?.context?.toString() ?? "",
       output = model?.output?.toString() ?? "",
       inputCost = model?.inputCost?.toString() ?? "",
       outputCost = model?.outputCost?.toString() ?? "",
       kind = switch (model) {
         ModelInfo(transcribes: true) => ModelRole.transcription,
         ModelInfo(speaks: true) => ModelRole.speech,
         ModelInfo() => ModelRole.text,
         null => role.voice ? role : ModelRole.text,
       },
       caps = {
         if (model?.toolCall ?? role == ModelRole.agent) ModelCap.toolCall,
         if (model?.reasoning ?? false) ModelCap.reasoning,
         if (model?.readsImages ?? false) ModelCap.readsImages,
         if (model?.readsPdfs ?? false) ModelCap.readsPdfs,
         if (model?.makesImages ?? role == ModelRole.image)
           ModelCap.makesImages,
       } {
    _initial = _answers;
  }

  final ModelRole role;

  /// Every configured provider, by id and name.
  final List<(String, String)> providers;

  final ModelInfo? model;
  final String? _editedOn;

  String provider;
  String id;
  String name;
  String context;
  String output;
  String inputCost;
  String outputCost;

  /// [ModelRole.text], [ModelRole.transcription] or [ModelRole.speech].
  ModelRole kind;
  Set<ModelCap> caps;

  late final List<Object> _initial;

  List<Object> get _answers => [
    provider,
    id,
    name,
    context,
    output,
    inputCost,
    outputCost,
    kind,
    ...ModelCap.values.map(caps.contains),
  ];

  bool get isNew => model == null;

  bool get chat => kind == ModelRole.text;

  /// Whether anything differs from what the page opened with.
  bool get edited {
    final now = _answers;
    for (var i = 0; i < now.length; i++) {
      if (now[i] != _initial[i]) return true;
    }
    return false;
  }

  /// "Not a number" where [text] is something other than one.
  static String? notNumber(String text, {bool decimal = false}) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final ok = decimal ? double.tryParse(t) != null : int.tryParse(t) != null;
    return ok ? null : "Not a number";
  }

  /// Whether Save may go: a provider and an id, and numbers where numbers
  /// go.
  bool get ready =>
      provider.isNotEmpty &&
      id.trim().isNotEmpty &&
      notNumber(context) == null &&
      notNumber(output) == null &&
      notNumber(inputCost, decimal: true) == null &&
      notNumber(outputCost, decimal: true) == null;

  /// What is saved: the model, the provider it is reached through, and the
  /// entry it replaces where it was an edit. A model that does not chat can
  /// do none of what [caps] says.
  ({String providerId, ModelInfo info, (String, String)? replacing}) build() {
    bool can(ModelCap cap) => chat && caps.contains(cap);
    final before = model;
    return (
      providerId: provider,
      info: ModelInfo(
        id: id.trim(),
        name: nonBlank(name),
        context: int.tryParse(nonBlank(context) ?? ""),
        output: int.tryParse(nonBlank(output) ?? ""),
        inputCost: double.tryParse(nonBlank(inputCost) ?? ""),
        outputCost: double.tryParse(nonBlank(outputCost) ?? ""),
        talks: chat,
        transcribes: kind == ModelRole.transcription,
        speaks: kind == ModelRole.speech,
        toolCall: can(ModelCap.toolCall),
        reasoning: can(ModelCap.reasoning),
        readsImages: can(ModelCap.readsImages),
        readsPdfs: can(ModelCap.readsPdfs),
        makesImages: can(ModelCap.makesImages),
      ),
      replacing: before == null ? null : (_editedOn!, before.id),
    );
  }
}

/// The providers a picker of [role] offers anything through: none for
/// transcription where the device cannot cut the microphone into utterances,
/// so no Default entry and no model to add is offered for one there.
List<LlmProviderConfig> pickerProviders(SettingReader ref, ModelRole role) {
  final cuts = ref.read(voiceProvider).hasModelCatalog;
  return role == ModelRole.transcription && !cuts
      ? const []
      : ref.read(appSettingsProvider).llmProviders;
}

/// The draft adding a model to a picker of [role] — on [providerId] where
/// the picker is narrowed to one — or editing [model], added by hand
/// earlier, on it. Null where [model] names one that is not there to edit.
CustomModelDraft? customModelDraft(
  SettingReader ref,
  ModelRole role, {
  String? providerId,
  String? model,
}) {
  final providers = pickerProviders(ref, role);
  // Only a model added by hand is edited.
  final info = model == null
      ? null
      : providers
            .where((p) => p.id == providerId)
            .firstOrNull
            ?.customModels
            .where((m) => m.id == model)
            .firstOrNull;
  if (model != null && info == null) return null;
  return CustomModelDraft(
    role: role,
    providers: [for (final p in providers) (p.id, p.displayName)],
    providerId: providerId,
    model: info,
  );
}

/// Keeps [draft] on its provider.
Future<void> saveCustomModel(SettingReader ref, CustomModelDraft draft) {
  final saved = draft.build();
  return ref
      .read(appSettingsProvider.notifier)
      .putCustomModel(saved.providerId, saved.info, replacing: saved.replacing);
}
