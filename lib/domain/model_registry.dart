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
/// machinery, which cannot wait on a channel round trip.
int? contextWindowOf(String? providerId, String? modelId) =>
    providerId == appleProviderId ? 8192 : null;