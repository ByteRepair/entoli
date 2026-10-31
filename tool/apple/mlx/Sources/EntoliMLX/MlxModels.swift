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

  /// Loads the model in `directory` and keeps it as `id`.
  public static func load(_ id: String, _ directory: String) async throws {
    _ = try await MlxModels.shared.load(id, directory)
  }

  public static func evict(_ id: String) async {
    await MlxModels.shared.evict(id)
  }

  /// One model call over `messages`, the whole conversation: what the model
  /// already holds of it is reused, and only the rest is read. `emit` hears
  /// the thinking, the reply and any tool calls as they come.
  ///
  /// **The model is the one `load` kept, never loaded here.** Dart's
  /// residency is the one account of what is loaded, and a generation that
  /// loaded behind it would hold weights that account does not know of.
  public static func generate(
    _ id: String,
    messages: [MlxMessage], tools: [MlxTool], temperature: Double?,
    emit: @escaping @Sendable (MlxEvent) -> Void
  ) async throws {
    guard let conversation = await MlxModels.shared.loaded(id) else { throw MlxNotLoaded() }
    try await conversation.generate(
      messages: messages, tools: tools, temperature: temperature, emit: emit)
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
  /// The end, with how much of the prompt was read and how much was reused.
  case done(promptTokens: Int, generatedTokens: Int)
}

/// A generation asked of a model `load` does not hold.
public struct MlxNotLoaded: Error, CustomStringConvertible {
  public var description: String { "The model is not loaded." }
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
  func load(_ id: String, _ directory: String) async throws -> MlxConversation {
    let loading = models[id] ?? Task {
      let container = try await loadModelContainer(
        from: URL(fileURLWithPath: directory), using: #huggingFaceTokenizerLoader())
      return MlxConversation(container)
    }
    models[id] = loading
    do {
      return try await loading.value
    } catch {
      models.removeValue(forKey: id)
      throw error
    }
  }

  func loaded(_ id: String) async -> MlxConversation? {
    try? await models[id]?.value
  }

  /// MLX keeps the buffers a model let go of for the next allocation, so
  /// dropping one frees nothing the system sees until its cache is emptied —
  /// a model unloaded from the settings page would otherwise go on holding
  /// its gigabytes.
  func evict(_ id: String) {
    models.removeValue(forKey: id)
    Memory.clearCache()
  }
}
