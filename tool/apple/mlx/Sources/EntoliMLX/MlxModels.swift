// With an SDK older than 27 mlx-swift-lm compiles to an empty module, which
// `canImport(MLXFoundationModels)` alone would still say yes to; this module
// is then empty too, and the channel's `canImport(EntoliMLX)` with it.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
internal import MLXFoundationModels
internal import MLXHuggingFace
internal import MLXLLM
internal import MLXLMCommon
internal import Tokenizers

/// The MLX models resident now, by catalog id. The weights are the
/// package's process-wide cache's; what is kept here is the instance a
/// session is built on, and the handle that evicts it. Dart decides which
/// are resident — see `MlxEngine`.
@available(iOS 27.0, macOS 27.0, *)
public actor MlxModels {
  public static let shared = MlxModels()

  private var models: [String: MLXLanguageModel] = [:]

  /// The model in `directory`, loaded and kept as `id`. Kept only once its
  /// weights are in: a load that throws leaves nothing behind for the next
  /// ask to find.
  public func load(_ id: String, _ directory: String) async throws -> any FoundationModels.LanguageModel {
    if let kept = models[id] { return kept }
    let url = URL(fileURLWithPath: directory)
    let model = MLXLanguageModel(
      configuration: ModelConfiguration(directory: url),
      capabilities: [.guidedGeneration, .toolCalling, .reasoning],
      weightsLocation: { _ in url },
      load: { _, _ in
        try await loadModelContainer(from: url, using: #huggingFaceTokenizerLoader())
      })
    try await model.preload()
    models[id] = model
    return model
  }

  public func evict(_ id: String) async {
    await models.removeValue(forKey: id)?.evict()
  }

  public func evictAll() async {
    models.removeAll()
    await MLXLanguageModel.evictAll()
  }
}
#endif
