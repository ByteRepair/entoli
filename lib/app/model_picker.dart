import "package:collection/collection.dart";

import "../data/builtin/llm/hosted_models.dart";
import "../data/builtin/llm/providers/provider.dart"
    show LlmProvider, resolveIn;
import "../domain/llm_provider.dart";
import "../domain/local_model.dart" show isTitleOnlyModel;
import "../domain/model_capability.dart";
import "../domain/model_registry.dart";
import "../domain/models.dart";
import "../providers.dart" show refOf;
import "model_role.dart";

/// One model a picker can offer, with the provider it is reached through.
class CatalogEntry {
  const CatalogEntry(
    this.providerId,
    this.providerName,
    this.info, {
    this.custom = false,
  });

  final String providerId;
  final String providerName;
  final ModelInfo info;

  /// Added by hand rather than listed by models.dev.
  final bool custom;

  ModelRef get ref => (providerId: providerId, modelId: info.id);

  /// What a search's words are looked for in, lower-cased.
  String get searched =>
      "${info.displayName} ${info.id} $providerName".toLowerCase();
}

/// A picker's page title: "Choose an image model".
String pickerTitle(ModelRole role) => "Choose ${role.article} ${role.noun}";

/// What a picker offers: each provider's models that [role] can use — the
/// on-device one's, then the configured ones' from the catalog — then whatever
/// the endpoints list that the catalog does not know, a self-hosted server's
/// models.
List<CatalogEntry> catalogEntries(
  ModelCatalog catalog,
  List<LlmProvider> providers,
  List<ModelOption> listed, {
  required ModelRole role,
  ModelHost? host,
}) {
  host ??= ModelHost.resolving();
  // Same-named models — one model through two providers — keep the order the
  // providers are configured in.
  final order = {for (final (i, p) in providers.indexed) p.id: i};
  final described = [
    for (final p in providers)
      for (final m in p.offered(catalog, host)) (provider: p, model: m),
  ];
  // Every model a provider describes, whatever this role makes of it: what
  // the catalog says of one wins over the endpoint naming it.
  final known = {for (final d in described) (d.provider.id, d.model.info.id)};
  final shown = <(String, String)>{};
  return [
    for (final (:provider, :model) in described)
      if (role.offers(model) && shown.add((provider.id, model.info.id)))
        CatalogEntry(
          provider.id,
          provider.displayName,
          model.info,
          custom: provider.config.customModels.any(
            (c) => c.id == model.info.id,
          ),
        ),
    // Named by their own listing — `<endpoint> · <model>` — and taken to be
    // chat models, since nothing says otherwise: no image model is guessed.
    if (role.chat)
      for (final o in listed)
        if (!known.contains((o.providerId, o.modelId)) &&
            (role == ModelRole.title ||
                !isTitleOnlyModel(o.providerId, o.modelId)))
          _listedEntry(o),
  ]..sort((a, b) {
    final byName = a.info.displayName.toLowerCase().compareTo(
      b.info.displayName.toLowerCase(),
    );
    return byName != 0
        ? byName
        : (order[a.providerId] ?? order.length).compareTo(
            order[b.providerId] ?? order.length,
          );
  });
}

CatalogEntry _listedEntry(ModelOption o) {
  final parts = (o.label ?? o.modelId).split(" · ");
  return CatalogEntry(
    o.providerId,
    parts.length > 1 ? parts.first : o.providerId,
    ModelInfo(id: o.modelId, name: parts.last, toolCall: true),
  );
}

/// What a model pick's field reads as. A voice model is named by what its
/// provider says of it, since no endpoint lists one, and nothing serving it
/// is as good as nothing chosen. A Default that names no model has nothing
/// to resolve to and reads as the null entry; a model is named by what the
/// catalog calls it, its id where nothing does; and one whose provider has
/// gone, from settings and from the on-device endpoints, leaves nothing that
/// could answer and reads as the null entry too.
String modelFieldLabel({
  required ModelChoice choice,
  required ModelRole role,
  required String nullLabel,
  required String? Function(LlmProviderConfig) defaultOf,
  required List<LlmProviderConfig> providers,
  required List<ModelOption> listed,
  required List<LlmProvider> serving,
}) {
  if (role.voice) {
    final pick = refOf(choice);
    return (pick == null
                ? null
                : resolveIn<Model>(serving, pick, (_) => ModelHost.resolving()))
            ?.info
            .displayName ??
        nullLabel;
  }
  final provider = providers.firstWhereOrNull((p) => p.id == choice.providerId);
  if (choice.modelId == null) {
    final model = provider == null ? null : defaultOf(provider);
    return model == null
        ? nullLabel
        : "${provider!.displayName} - Default ($model)";
  }
  final reachable =
      provider != null ||
      choice.providerId == null ||
      listed.any((m) => m.providerId == choice.providerId);
  return reachable ? modelName(providers, listed, choice) : nullLabel;
}

/// A chosen model by the name the catalog gives it, then the on-device list's,
/// then its id; "the app default" where nothing is chosen.
String modelName(
  List<LlmProviderConfig> providers,
  List<ModelOption> listed,
  ModelChoice choice,
) {
  final provider = providers.firstWhereOrNull((p) => p.id == choice.providerId);
  final model =
      choice.modelId ??
      (provider == null ? null : LlmProviderConfig.chatDefaultOf(provider));
  if (model == null) return "the app default";
  return modelInfoOf(provider, model)?.name ??
      listed
          // A model stored without its provider, as an older chat's was.
          .firstWhereOrNull(
            (m) =>
                m.modelId == model &&
                (choice.providerId == null ||
                    m.providerId == choice.providerId),
          )
          ?.label ??
      model;
}

/// An entry above the models that stores less than one: the null entry, or
/// a provider's Default and the model it resolves to.
typedef QuickPick = ({
  String? providerId,
  String title,
  String? subtitle,
  bool selected,
});

/// What a picker shows of [entries] beyond the list itself: its quick picks,
/// the favourites it can offer in the order they were starred — the order
/// they were wanted — the providers it can narrow to, and what it says with
/// nothing to show.
({
  List<QuickPick> quick,
  List<CatalogEntry> starred,
  Map<String, String> providers,
  String emptyNote,
  String noneTitle,
})
pickerView({
  required List<CatalogEntry> entries,
  required List<LlmProviderConfig> providers,
  required List<ModelRef> favourites,
  required ModelChoice choice,
  required ModelRole role,
  required String nullLabel,
  required String? Function(LlmProviderConfig) defaultOf,
  bool searching = false,
}) {
  bool picked(String? providerId, String? modelId) =>
      choice.providerId == providerId && choice.modelId == modelId;
  final byRef = {for (final e in entries) e.ref: e};
  final media = searching ? null : role.emptyNote;
  return (
    quick: [
      (
        providerId: null,
        title: nullLabel,
        subtitle: null,
        selected: picked(null, null),
      ),
      for (final p in providers)
        if (defaultOf(p) case final model?)
          (
            providerId: p.id,
            title: "${p.displayName} - Default",
            subtitle: modelInfoOf(p, model)?.displayName ?? model,
            selected: picked(p.id, null),
          ),
    ],
    starred: [for (final f in favourites) ?byRef[f]],
    providers: {
      for (final p in providers) p.id: p.displayName,
      for (final e in entries) e.providerId: e.providerName,
    }..removeWhere((id, _) => !entries.any((e) => e.providerId == id)),
    noneTitle: media != null ? "No ${role.noun}s" : "No model matches",
    emptyNote: providers.isEmpty && !role.voice
        ? "Add a provider in Settings > Providers to see its models."
        : media ??
              "Not every model is in the catalog. A fine-tune or a private "
                  "deployment can be added by hand.",
  );
}

/// Why a model pick's field is wrong: the provider it names is not here —
/// removed from settings, or a device's model this one has not got — said
/// in the turn error's words, since a turn on it fails and the field must
/// not claim it would run on something else. Only once the list [loaded],
/// so a field opened before it is not briefly an error.
String? modelFieldError({
  required ModelChoice choice,
  required ModelRole role,
  required bool loaded,
  required List<ModelOption> listed,
  required List<LlmProvider> serving,
}) {
  final id = choice.providerId;
  if (role.voice || !loaded || id == null) return null;
  if (serving.any((p) => p.id == id) || listed.any((m) => m.providerId == id)) {
    return null;
  }
  return missingProviderMessage(choice.modelId, id);
}

/// What a field whose [modelFieldError] says its provider is gone reads as.
const missingModelLabel = "Select New Model";
