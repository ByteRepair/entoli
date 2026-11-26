import Foundation
internal import MLX
internal import MLXHuggingFace
internal import MLXLLM
internal import MLXLMCommon
internal import Tokenizers

/// The MLX models, as the channel reaches them: load, generate, save and
/// restore a model's prompt state, unload. Every call answers on any OS the
/// app runs on, and the one gate — the OS the feature is offered on — is
/// here, said once.
public enum Mlx {
  public static var isAvailable: Bool {
    if #available(iOS 27.0, macOS 27.0, *) { return true }
    return false
  }

  /// Loads the model in `directory` and keeps it as `id`, held to `limits`
  /// where the app planned any.
  public static func load(_ id: String, _ directory: String, limits: MlxLimits?) async throws {
    _ = try await MlxModels.shared.load(id, directory, limits: limits)
  }

  public static func evict(_ id: String) async {
    // Evicted whatever MLX says: what failed was the model being let go of.
    _ = try? await catchingMlx { _ in await MlxModels.shared.evict(id) }
  }

  /// One model call over `messages`, the whole conversation: what the model
  /// already holds of it is reused, and only the rest is read. `emit` hears
  /// the thinking, the reply and any tool calls as they come.
  ///
  /// **The model is the one `load` kept, never loaded here.** Dart's
  /// residency is the one account of what is loaded, and a generation that
  /// loaded behind it would hold weights that account does not know of.
  ///
  /// `maxTokens` is the most the reply may run to, the app's Maximum response
  /// length or the model's own; the reply that reaches it was cut off there.
  public static func generate(
    _ id: String,
    messages: [MlxMessage], tools: [MlxTool], temperature: Double?, maxTokens: Int,
    emit: @escaping @Sendable (MlxEvent) -> Void
  ) async throws {
    guard let conversation = await MlxModels.shared.loaded(id) else { throw MlxNotLoaded() }
    try await conversation.generate(
      messages: messages, tools: tools, temperature: temperature, maxTokens: maxTokens,
      emit: emit)
  }

  /// Writes what `id` holds to `path`. False where it holds nothing.
  public static func save(_ id: String, to path: String) async -> Bool {
    guard let conversation = await MlxModels.shared.loaded(id) else { return false }
    return await conversation.save(to: path)
  }

  /// Reads `path` back as what `id` holds. False where it could not.
  public static func restore(_ id: String, from path: String) async -> Bool {
    guard let conversation = await MlxModels.shared.loaded(id) else { return false }
    return await conversation.restore(from: path)
  }

  /// What `id` takes up: its weights' bytes, and how many tokens its cache
  /// holds — which the app turns into bytes by what one costs. Nil where it
  /// is not loaded.
  public static func usage(_ id: String) async -> (weightBytes: Int, tokens: Int)? {
    guard let conversation = await MlxModels.shared.loaded(id) else { return nil }
    return await conversation.usage()
  }
}

/// One message of a conversation, the shape the app sends: a role, its text,
/// the tool calls an assistant made, and which call a tool result answers.
public struct MlxMessage: Sendable, Codable {
  public enum Role: String, Sendable, Codable { case system, user, assistant, tool }

  public var role: Role
  public var content: String
  public var toolCalls: [MlxToolCall]
  public var toolCallID: String?

  public init(
    role: Role, content: String, toolCalls: [MlxToolCall] = [], toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  /// The message as the channel carries it: `role`, `content`, `toolCalls`
  /// (`id`, `name`, `arguments` as JSON text) and `toolCallId`. The keys are
  /// read here, beside the type, so the Runner only forwards the map.
  public init(channel map: [String: Any]) {
    self.init(
      role: Role(rawValue: map["role"] as? String ?? "") ?? .user,
      content: map["content"] as? String ?? "",
      toolCalls: (map["toolCalls"] as? [[String: Any]] ?? []).map {
        MlxToolCall(
          id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
          arguments: $0["arguments"] as? String ?? "{}")
      },
      toolCallID: map["toolCallId"] as? String)
  }
}

/// A tool call, its arguments as the JSON text they were written as.
public struct MlxToolCall: Sendable, Codable, Equatable {
  public var id: String
  public var name: String
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

/// A tool the model is offered, its parameters as a JSON schema's text —
/// text rather than the values, so the record a saved cache keeps can be
/// written and compared as it is.
public struct MlxTool: Sendable, Codable, Equatable {
  public var name: String
  public var description: String
  public var parameters: String

  public init(name: String, description: String, parameters: String) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }

  /// The tool as the channel carries it: `name`, `description` and `schema`,
  /// the JSON schema as a map.
  public init(channel map: [String: Any]) {
    self.init(
      name: map["name"] as? String ?? "",
      description: map["description"] as? String ?? "",
      parameters: jsonText(map["schema"] ?? [String: Any]()))
  }
}

/// What a generation says, in order.
public enum MlxEvent: Sendable {
  case reasoning(String)
  case text(String)
  case toolCall(MlxToolCall)
  /// The end, with how much of the prompt was read and how much was reused,
  /// the most memory MLX held while it ran, and MLX's budget where the app
  /// planned one.
  case done(promptTokens: Int, generatedTokens: Int, peakBytes: Int, budgetBytes: Int?)
}

/// A failure MLX raised itself, coded as the channel's `error` frame is: the
/// GPU refused off screen (`background`), memory ran out (`resources`), or
/// anything else (`other`).
public struct MlxFailure: Error, CustomStringConvertible {
  public let code: String
  public let description: String

  /// A reply stopped at the memory the app planned for its model.
  static let overBudget = MlxFailure(
    code: "resources", description: "The model outgrew the memory set aside for it.")

  /// A prompt longer than the model has room for.
  static let outgrewContext = MlxFailure(
    code: "context", description: "The conversation is longer than the model has room for.")

  init(code: String, description: String) {
    self.code = code
    self.description = description
  }

  init(_ message: String) {
    description = message
    if message.contains("BackgroundExecutionNotPermitted") {
      code = "background"
    } else if ["OutOfMemory", "Insufficient Memory", "malloc]"].contains(where: { message.contains($0) }) {
      code = "resources"
    } else {
      code = "other"
    }
  }
}

/// Runs `body` with MLX's errors thrown as `MlxFailure`. With no scoped
/// handler MLX calls `fatalError`, so a refused command buffer or a failed
/// allocation killed the app with nothing said. The handler is task-local:
/// it reaches mlx-swift-lm's generation tasks, not the weight loading it
/// runs on a dispatch queue.
func catchingMlx<T>(_ body: (ErrorBox) async throws -> T) async throws -> T {
  do {
    return try await withError(body)
  } catch MLXError.caught(let message) {
    throw MlxFailure(message)
  }
}

/// A generation asked of a model `load` does not hold.
public struct MlxNotLoaded: Error, CustomStringConvertible {
  public var description: String { "The model is not loaded." }
}

/// A generation ended because its model was unloaded under it.
public struct MlxUnloaded: Error, CustomStringConvertible {
  public var description: String { "The model was unloaded." }
}

/// The MLX models loaded now, by catalog id. Dart decides which are loaded —
/// see `Residency` — so this keeps what it is told and nothing more.
actor MlxModels {
  static let shared = MlxModels()

  /// Each model's load, by id: a second ask while the weights are still being
  /// read — the actor gives way at that await — waits on the first rather than
  /// reading them again.
  private var models: [String: Task<MlxConversation, Error>] = [:]

  /// The model in `directory`, loaded and kept as `id`. A load that throws
  /// leaves nothing behind for the next ask to find.
  ///
  /// The weights are read on a dispatch queue, out of reach of MLX's error
  /// handler and of any check a reply makes, so whether they fit is the
  /// app's plan's to say before asking (`BudgetPlan.refusal`).
  func load(_ id: String, _ directory: String, limits: MlxLimits?) async throws -> MlxConversation {
    if models[id] == nil { MlxBudget.shared.admit(id, limits) }
    // MLX's errors caught inside the task, so a failed load throws from it
    // and is not kept, and every caller waiting on it hears the same.
    let loading = models[id] ?? Task {
      try await catchingMlx { _ in
        let container = try await loadModelContainer(
          from: URL(fileURLWithPath: directory), using: #huggingFaceTokenizerLoader())
        // Counted now, while nothing else holds the model.
        let weightBytes = await container.perform { context in
          context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
        }
        return MlxConversation(container, weightBytes: weightBytes, limits: limits)
      }
    }
    models[id] = loading
    do {
      return try await loading.value
    } catch {
      if models.removeValue(forKey: id) != nil { MlxBudget.shared.release(id) }
      throw error
    }
  }

  func loaded(_ id: String) async -> MlxConversation? {
    try? await models[id]?.value
  }

  /// MLX keeps what a model lets go of in its buffer cache and never gives it
  /// back on its own, so an unloaded model's gigabytes would stay with the
  /// process. The model is let go of before its unload returns — see
  /// `MlxConversation` — and the cache is emptied of it once, here.
  ///
  /// Not quite all of it is let go of by then: mlx-swift-lm's reply task
  /// drops its hold on the model as it exits, a moment after the session's
  /// wait for it returns, and nothing says when. So with no model left the
  /// cache's limit is taken to nothing (`MlxBudget`), and MLX hands back
  /// whatever is freed from then on as it is freed. While a model is loaded,
  /// what is freed is kept for it, up to its budget's share.
  func evict(_ id: String) async {
    if let conversation = try? await models.removeValue(forKey: id)?.value {
      await conversation.unload()
    }
    MlxBudget.shared.release(id)
    Memory.clearCache()
  }

}
