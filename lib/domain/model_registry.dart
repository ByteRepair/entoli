import "local_model.dart";

/// What the app knows of a model, where the settings' one global guess is not
/// the answer.
///
/// No service maps a model id to its context window and none is asked at
/// runtime: a model whose window is known is named here, and everything else
/// answers null, which every caller is expected to read as "use
/// `AppSettings.totalContext`", the app-wide guess. This is a heuristic, not
/// a lookup — entries are corrected by hand when a model's window is learned,
/// and the metadata the app actually reads (devices, licences, capabilities)
/// lives with the ports that carry it.
///
/// The Apple on-device model: `SystemLanguageModel.contextSize` reads 8,192
/// on the OS today, and the framework only exposes it from 26.4 on — one
/// constant here is what that is while the reader is the compaction
/// machinery, which cannot wait on a channel round trip. The provider's MLX
/// rows are other models whose windows are their own: they answer null, the
/// global guess, and a null model id is the provider's default — the system
/// model.
int? contextWindowOf(String? providerId, String? modelId) {
  if (providerId != appleProviderId) return null;
  if (modelId != null && modelId != appleModelId) return null;
  return 8192;
}
