import Foundation
internal import MLXLMCommon

/// One loaded model and the conversation its cache holds.
///
/// **What the cache already holds is not read again.** The app sends the whole
/// conversation on every call — nothing is held between turns on its side —
/// and an agent's turn is many calls, each the last plus a tool's result. So
/// the session is kept, with the messages it has taken in, its own reply
/// included: a call that carries those on gets only its new messages read,
/// and one that does not starts a session over the whole of it. Reading the
/// agent's prompt once rather than every step is the difference between a
/// tool round of seconds and one of a minute. A model whose cache cannot be
/// rewound — Qwen3.5's recurrent layers — is served by exactly this, since an
/// agent's turn only ever extends what came before.
actor MlxConversation {
  init(_ container: ModelContainer) {
    self.container = container
  }

  private let container: ModelContainer

  private var session: ChatSession?

  /// What `session`'s cache covers, in the app's words, with the tools it was
  /// rendered under: a different tool list is a different prompt.
  private var held: [MlxMessage] = []
  private var heldTools: [MlxTool] = []

  /// Long enough for any reply an agent's step has, short of a model that
  /// never stops.
  private static let maxTokens = 8192

  func generate(
    messages: [MlxMessage], tools: [MlxTool], temperature: Double?,
    emit: @Sendable (MlxEvent) -> Void
  ) async throws {
    guard let last = messages.last else { return }
    var parameters = GenerateParameters(maxTokens: Self.maxTokens)
    if let temperature { parameters.temperature = Float(temperature) }

    let fresh: [MlxMessage]
    if let session, carriesOn(messages, tools) {
      session.generateParameters = parameters
      fresh = Array(messages[held.count...])
    } else {
      session = ChatSession(
        container, history: messages.dropLast().map(\.chat),
        generateParameters: parameters, tools: tools.map(\.spec))
      fresh = [last]
    }
    // Cleared until the reply is in: a generation stopped part-way leaves a
    // cache that holds some of a reply nobody kept, so the next call starts
    // over rather than carrying on from that.
    held = []

    var thinking = try await ThinkingSplitter(container, messages, tools)
    var reply = ""
    var calls: [MlxToolCall] = []
    var counts = (prompt: 0, generated: 0)
    for try await generation in session!.streamDetails(to: fresh.map(\.chat)) {
      switch generation {
      case .chunk(let chunk):
        for piece in thinking.feed(chunk) {
          emit(piece.reasoning ? .reasoning(piece.text) : .text(piece.text))
          if !piece.reasoning { reply += piece.text }
        }
      case .toolCall(let call):
        let made = MlxToolCall(
          id: "c\(calls.count)", name: call.function.name,
          arguments: Self.json(call.function.arguments))
        calls.append(made)
        emit(.toolCall(made))
      case .rejectedToolCall(let rejection):
        throw MlxRejected(description: "\(rejection)")
      case .info(let info):
        counts = (info.promptTokenCount, info.generationTokenCount)
      }
    }
    for piece in thinking.finish() {
      emit(piece.reasoning ? .reasoning(piece.text) : .text(piece.text))
      if !piece.reasoning { reply += piece.text }
    }
    held = messages + [MlxMessage(role: .assistant, content: reply, toolCalls: calls)]
    heldTools = tools
    emit(.done(promptTokens: counts.prompt, generatedTokens: counts.generated))
  }

  /// Whether `messages` is what the session holds and more: the same messages
  /// in the same order, under the same tools. A reply this session wrote comes
  /// back as the app recorded it, so it is matched by its text and calls
  /// rather than by the ids the app gave them.
  private func carriesOn(_ messages: [MlxMessage], _ tools: [MlxTool]) -> Bool {
    !held.isEmpty && messages.count > held.count && tools == heldTools
      && zip(held, messages).allSatisfy { $0.sameAs($1) }
  }

  /// Writes the cache to `path` and what it holds beside it, `path.json`: a
  /// cache file says nothing of which messages it covers, and a session
  /// restored without that would read its own reply a second time.
  func save(to path: String) async -> Bool {
    guard let session, !held.isEmpty else { return false }
    do {
      try await session.saveCache(to: URL(fileURLWithPath: path))
      let record = HeldRecord(messages: held, tools: heldTools)
      try JSONEncoder().encode(record).write(to: Self.companion(path), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  func restore(from path: String) async -> Bool {
    do {
      let record = try JSONDecoder().decode(
        HeldRecord.self, from: Data(contentsOf: Self.companion(path)))
      let snapshot = try loadPromptCacheSnapshot(url: URL(fileURLWithPath: path))
      session = ChatSession(
        container, cache: snapshot.cache, state: snapshot.state,
        tools: record.tools.map(\.spec))
      held = record.messages
      heldTools = record.tools
      return true
    } catch {
      return false
    }
  }

  private static func companion(_ path: String) -> URL {
    URL(fileURLWithPath: path + ".json")
  }

  private static func json(_ arguments: [String: JSONValue]) -> String {
    guard let data = try? JSONEncoder().encode(arguments) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// A tool call the model wrote that names no tool it was offered, or will not
/// parse.
struct MlxRejected: Error, CustomStringConvertible {
  let description: String
}

private struct HeldRecord: Codable {
  let messages: [MlxMessage]
  let tools: [MlxTool]
}

/// A model's output split into its thinking and its reply, by the markers its
/// configuration names. A template that opens the thinking itself — Qwen3.5's,
/// which ends the prompt inside `<think>` — starts the output inside it, which
/// is told by rendering the prompt and reading its end, as the model will.
struct ThinkingSplitter {
  private let start: String
  private let end: String
  private var inside: Bool
  /// The tail of what arrived that may be the start of a marker, held until
  /// the next chunk says whether it is.
  private var pending = ""
  /// Whether the reply has started, so the blank lines after a marker are not
  /// its first words.
  private var replyStarted = false

  init(_ container: ModelContainer, _ messages: [MlxMessage], _ tools: [MlxTool]) async throws {
    let found: (String, String, Bool)? = try await container.perform { context in
      guard let config = context.configuration.reasoningConfig else { return nil }
      let tokens = try context.tokenizer.applyChatTemplate(
        messages: messages.map(\.dictionary), tools: tools.map(\.spec),
        additionalContext: nil)
      let tail = context.tokenizer.decode(tokenIds: Array(tokens.suffix(8)))
      let primed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix(config.startDelimiter)
      return (config.startDelimiter, config.endDelimiter, primed)
    }
    (start, end, inside) = found ?? ("", "", false)
  }

  /// No markers is a model that does not think: everything is reply.
  private var thinks: Bool { !start.isEmpty && !end.isEmpty }

  mutating func feed(_ chunk: String) -> [(reasoning: Bool, text: String)] {
    guard thinks else { return reply(chunk) }
    var text = pending + chunk
    pending = ""
    var pieces: [(reasoning: Bool, text: String)] = []
    while !text.isEmpty {
      let marker = inside ? end : start
      if let found = text.range(of: marker) {
        let before = String(text[..<found.lowerBound])
        pieces += inside ? thought(before) : reply(before)
        inside.toggle()
        text = String(text[found.upperBound...])
        continue
      }
      // Hold back what may be the first characters of the marker.
      let keep = Self.partialSuffix(of: text, prefixing: marker)
      let ready = String(text.dropLast(keep))
      pending = String(text.suffix(keep))
      pieces += inside ? thought(ready) : reply(ready)
      break
    }
    return pieces
  }

  mutating func finish() -> [(reasoning: Bool, text: String)] {
    let rest = pending
    pending = ""
    return inside ? thought(rest) : reply(rest)
  }

  private func thought(_ text: String) -> [(reasoning: Bool, text: String)] {
    text.isEmpty ? [] : [(true, text)]
  }

  private mutating func reply(_ text: String) -> [(reasoning: Bool, text: String)] {
    var text = text
    if !replyStarted {
      text = String(text.drop { $0.isWhitespace })
      if text.isEmpty { return [] }
      replyStarted = true
    }
    return [(false, text)]
  }

  /// How many trailing characters of `text` are the start of `marker`.
  private static func partialSuffix(of text: String, prefixing marker: String) -> Int {
    for length in stride(from: min(marker.count - 1, text.count), to: 0, by: -1) {
      if marker.hasPrefix(text.suffix(length)) { return length }
    }
    return 0
  }
}

extension MlxMessage {
  /// The same message, as far as the model's cache is concerned: role, text
  /// and the calls an assistant made, ids aside.
  func sameAs(_ other: MlxMessage) -> Bool {
    role == other.role
      && content.trimmingCharacters(in: .whitespacesAndNewlines)
        == other.content.trimmingCharacters(in: .whitespacesAndNewlines)
      && toolCalls.map { [$0.name, $0.arguments] } == other.toolCalls.map { [$0.name, $0.arguments] }
      && (role != .tool || toolCallID == other.toolCallID)
  }

  var chat: Chat.Message {
    switch role {
    case .system: .system(content)
    case .user: .user(content)
    case .tool: .tool(content, id: toolCallID)
    case .assistant:
      .assistant(
        content,
        toolCalls: toolCalls.isEmpty
          ? nil
          : toolCalls.map {
            ToolCall(
              function: .init(name: $0.name, arguments: jsonObject($0.arguments)), id: $0.id)
          })
    }
  }

  /// The OpenAI shape a chat template reads.
  var dictionary: [String: any Sendable] {
    var out: [String: any Sendable] = ["role": role.rawValue, "content": content]
    if !toolCalls.isEmpty {
      out["tool_calls"] = toolCalls.map { call -> [String: any Sendable] in
        [
          "id": call.id, "type": "function",
          "function": ["name": call.name, "arguments": jsonObject(call.arguments)] as [String: any Sendable],
        ]
      }
    }
    if let toolCallID { out["tool_call_id"] = toolCallID }
    return out
  }
}

extension MlxTool {
  /// The OpenAI shape a chat template reads.
  var spec: ToolSpec {
    [
      "type": "function",
      "function": [
        "name": name, "description": description, "parameters": jsonObject(parameters),
      ] as [String: any Sendable],
    ]
  }
}

/// A JSON object's text as the values a template reads. Anything that is not
/// an object is an empty one.
func jsonObject(_ text: String) -> [String: any Sendable] {
  guard let data = text.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return [:] }
  return object.mapValues(sendable)
}

private func sendable(_ value: Any) -> any Sendable {
  switch value {
  case let object as [String: Any]: object.mapValues(sendable)
  case let array as [Any]: array.map(sendable)
  case let number as NSNumber:
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      number.boolValue
    } else if number.doubleValue.rounded() == number.doubleValue {
      number.intValue
    } else {
      number.doubleValue
    }
  case let string as String: string
  default: ""
  }
}
