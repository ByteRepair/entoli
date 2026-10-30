// With an SDK older than 27 mlx-swift-lm compiles to an empty module, and
// this one would too — a framework the app links that answers `mlx: false`
// everywhere, and nothing going red. So it is an error instead.
#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
internal import MLXFoundationModels
internal import MLXHuggingFace
internal import MLXLLM
internal import MLXLMCommon
internal import Tokenizers

/// The MLX models, as the channel reaches them: every call answers on any
/// OS the app runs on, and the one gate — an OS that carries no model
/// behind FoundationModels' `LanguageModel` — is here, said once.
public enum Mlx {
  public static var isAvailable: Bool {
    if #available(iOS 27.0, macOS 27.0, *) { return true }
    return false
  }

  /// Loads the model in `directory` and keeps it as `id`.
  public static func load(_ id: String, _ directory: String) async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { throw MlxUnavailable() }
    _ = try await MlxModels.shared.load(id, directory)
  }

  public static func evict(_ id: String) async {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    await MlxModels.shared.evict(id)
  }

  public static func evictAll() async {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    await MlxModels.shared.evictAll()
  }

  /// A session on the kept model, loaded first where it is not kept.
  @available(iOS 26.0, macOS 26.0, *)
  public static func session(
    _ id: String, _ directory: String, tools: [any FoundationModels.Tool], transcript: FoundationModels.Transcript
  ) async throws -> LanguageModelSession {
    guard #available(iOS 27.0, macOS 27.0, *) else { throw MlxUnavailable() }
    return LanguageModelSession(
      model: try await MlxModels.shared.load(id, directory),
      tools: tools,
      transcript: transcript)
  }
}

public struct MlxUnavailable: Error, CustomStringConvertible {
  public var description: String { "This OS does not carry MLX models." }
}

/// The MLX models resident now, by catalog id. The weights are the
/// package's process-wide cache's; what is kept here is the instance a
/// session is built on, and the handle that evicts it. Dart decides which
/// are resident — see `MlxEngine`.
@available(iOS 27.0, macOS 27.0, *)
actor MlxModels {
  static let shared = MlxModels()

  private var models: [String: MLXLanguageModel] = [:]

  /// The model in `directory`, loaded and kept as `id`. Kept only once its
  /// weights are in: a load that throws leaves nothing behind for the next
  /// ask to find.
  func load(_ id: String, _ directory: String) async throws -> MLXLanguageModel {
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

  func evict(_ id: String) async {
    await models.removeValue(forKey: id)?.evict()
  }

  func evictAll() async {
    models.removeAll()
    await MLXLanguageModel.evictAll()
  }
}
#else
#error("EntoliMLX needs the iOS 27 and macOS 27 SDKs: build it with Xcode 27.")
#endif
