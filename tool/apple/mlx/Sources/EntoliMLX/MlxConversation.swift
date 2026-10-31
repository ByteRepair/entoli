import Foundation
internal import MLX
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
///
/// **It owns its model, and lets go of it in one place.** The weights are held
/// by the container, and by the session built over it; a generation, a save
/// or a restore holds them too while it runs, and so does the task
/// mlx-swift-lm runs each reply in. Each of ours runs as an operation the
/// conversation counts, and `unload` refuses new ones, stops a generation,
/// waits for the rest and for the session's own task, and then drops the
/// session and the container itself — so when it returns, nothing holds the
/// model, rather than whenever a straggler finishes.
actor MlxConversation {
  init(_ container: ModelContainer, weightBytes: Int) {
    self.container = container
    self.weightBytes = weightBytes
  }

  /// The model: what holds its weights. Nil once unloaded.
  private var container: ModelContainer?

  private var session: ChatSession?

  /// What `session`'s cache covers, in the app's words, with the tools it was
  /// rendered under: a different tool list is a different prompt. Nothing
  /// where the session holds nothing a call could carry on from.
  private var held: HeldRecord?

  /// The template's thinking markers, read at the first generation and kept:
  /// they are the model's, not the conversation's.
  private var markers: ThinkingMarkers?

  /// Long enough for any reply an agent's step has, short of a model that
  /// never stops.
  private static let maxTokens = 8192

  /// Stops the generation under way: a model let go of is not one a reply may
  /// go on coming from.
  private var stopGeneration: (@Sendable () -> Void)?
  private var unloaded = false

  /// How many operations are running, and the unload waiting for none to be.
  private var operations = 0
  private var whenIdle: [CheckedContinuation<Void, Never>] = []

  /// Runs `body` as one of the operations an unload waits for, handing it the
  /// model; throws `MlxUnloaded` once the model is being let go of. Whatever
  /// `body` holds is let go of before the count falls, since nothing awaits
  /// between its return and the unload that count wakes running on this
  /// actor.
  private func operation<T>(_ body: (ModelContainer) async throws -> T) async throws -> T {
    guard !unloaded, let container else { throw MlxUnloaded() }
    operations += 1
    defer {
      operations -= 1
      if operations == 0 {
        whenIdle.forEach { $0.resume() }
        whenIdle = []
      }
    }
    return try await body(container)
  }

  /// Refuses what comes next, stops a generation, waits for every operation
  /// to end, then lets go of the model. Returns once nothing holds it.
  ///
  /// A generation's end here is not the end of its work: mlx-swift-lm runs
  /// each reply in a task of its own, which a stopped reader only asks to
  /// stop, and which goes on holding the model and its cache until the
  /// generation has wound down — for the rest of a prompt still being read.
  /// `synchronize` is the session's own wait for that.
  func unload() async {
    unloaded = true
    stopGeneration?()
    while operations > 0 {
      await withCheckedContinuation { whenIdle.append($0) }
    }
    await session?.synchronize()
    session = nil
    held = nil
    container = nil
  }

  func generate(
    messages: [MlxMessage], tools: [MlxTool], temperature: Double?,
    emit: @escaping @Sendable (MlxEvent) -> Void
  ) async throws {
    try await operation { container in
      guard let last = messages.last else { return }
      var parameters = GenerateParameters(maxTokens: Self.maxTokens)
      if let temperature { parameters.temperature = Float(temperature) }

      let fresh: [MlxMessage]
      if let session, let held, held.carriesOn(messages, tools) {
        session.generateParameters = parameters
        fresh = Array(messages[held.messages.count...])
      } else {
        session = ChatSession(
          container, history: messages.dropLast().map(\.chat),
          generateParameters: parameters, tools: tools.map(\.spec))
        fresh = [last]
      }
      // Cleared until the reply is in: a generation stopped part-way leaves a
      // cache that holds some of a reply nobody kept, so the next call starts
      // over rather than carrying on from that.
      held = nil

      if markers == nil { markers = try await ThinkingMarkers(container) }
      let markers = self.markers!
      let stream = session!.streamDetails(to: fresh.map(\.chat))
      // In a task of its own, so an unload can cancel it whoever is waiting
      // on it; a stop from the caller reaches it the same way.
      let work = Task { () throws -> (reply: String, calls: [MlxToolCall], counts: (Int, Int)) in
        var thinking = ThinkingSplitter(markers)
        var reply = ""
        // Said as they come, the reply's text kept for the record.
        func say(_ events: [MlxEvent]) {
          for event in events {
            emit(event)
            if case .text(let text) = event { reply += text }
          }
        }
        var calls: [MlxToolCall] = []
        var counts = (prompt: 0, generated: 0)
        for try await generation in stream {
          try Task.checkCancellation()
          switch generation {
          case .chunk(let chunk):
            say(thinking.feed(chunk))
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
        try Task.checkCancellation()
        say(thinking.finish())
        return (reply, calls, counts)
      }
      stopGeneration = { work.cancel() }
      defer { stopGeneration = nil }
      let outcome: (reply: String, calls: [MlxToolCall], counts: (Int, Int))
      do {
        outcome = try await withTaskCancellationHandler {
          try await work.value
        } onCancel: {
          work.cancel()
        }
      } catch {
        if unloaded { throw MlxUnloaded() }
        throw error
      }
      held = HeldRecord(
        messages: messages + [
          MlxMessage(role: .assistant, content: outcome.reply, toolCalls: outcome.calls)
        ],
        tools: tools)
      heldTokens = (try? await session?.cacheStatus().processedTokenCount ?? nil) ?? 0
      emit(.done(promptTokens: outcome.counts.0, generatedTokens: outcome.counts.1))
    }
  }

  /// The weights' bytes, counted at load, and the tokens the cache held when
  /// a generation last ended — what the settings page shows, answered from
  /// what is already known: asking the model would wait out a generation's
  /// whole reading of its prompt, which holds it.
  private let weightBytes: Int
  private var heldTokens = 0

  func usage() -> (weightBytes: Int, tokens: Int) { (weightBytes, heldTokens) }

  /// Writes the cache to `path` and what it holds beside it, `path.json`: a
  /// cache file says nothing of which messages it covers, and a session
  /// restored without that would read its own reply a second time.
  func save(to path: String) async -> Bool {
    (try? await operation { _ in
      guard let session, let held else { return false }
      try await session.saveCache(to: URL(fileURLWithPath: path))
      try JSONEncoder().encode(held).write(to: Self.companion(path), options: .atomic)
      return true
    }) ?? false
  }

  func restore(from path: String) async -> Bool {
    (try? await operation { container in
      let record = try JSONDecoder().decode(
        HeldRecord.self, from: Data(contentsOf: Self.companion(path)))
      let snapshot = try loadPromptCacheSnapshot(url: URL(fileURLWithPath: path))
      session = ChatSession(
        container, cache: snapshot.cache, state: snapshot.state,
        tools: record.tools.map(\.spec))
      held = record
      heldTokens = (try? await session?.cacheStatus().processedTokenCount ?? nil) ?? 0
      return true
    }) ?? false
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

/// The messages a session's cache covers and the tools they were rendered
/// under — kept with the session, and written beside a saved cache.
private struct HeldRecord: Codable {
  let messages: [MlxMessage]
  let tools: [MlxTool]

  /// Whether `messages` is this and more: the same messages in the same
  /// order, under the same tools. A reply the session wrote comes back as the
  /// app recorded it, so it is matched by its text and calls rather than by
  /// the ids the app gave them.
  func carriesOn(_ messages: [MlxMessage], _ tools: [MlxTool]) -> Bool {
    !self.messages.isEmpty && messages.count > self.messages.count && tools == self.tools
      && zip(self.messages, messages).allSatisfy { $0.sameAs($1) }
  }
}

/// A model's thinking markers, as its configuration names them, and whether
/// its template opens the thinking itself — Qwen3.5's ends the prompt inside
/// `<think>`, so the output starts inside it. That is the template's doing,
/// not the conversation's, so it is told once per model from the smallest
/// prompt there is, one user message and no tools, rendered and its end read
/// as the model will: rendering the whole conversation for it held back the
/// first output of every step.
struct ThinkingMarkers: Sendable {
  let start: String
  let end: String
  let primed: Bool

  init(_ container: ModelContainer) async throws {
    let found: (String, String, Bool)? = try await container.perform { context in
      guard let config = context.configuration.reasoningConfig else { return nil }
      let tokens = try context.tokenizer.applyChatTemplate(
        messages: [["role": "user", "content": "Hi"]], tools: nil, additionalContext: nil)
      let tail = context.tokenizer.decode(tokenIds: Array(tokens.suffix(8)))
      let primed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasSuffix(config.startDelimiter)
      return (config.startDelimiter, config.endDelimiter, primed)
    }
    (start, end, primed) = found ?? ("", "", false)
  }
}

/// A model's output split into its thinking and its reply, by its markers.
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

  init(_ markers: ThinkingMarkers) {
    (start, end, inside) = (markers.start, markers.end, markers.primed)
  }

  /// No markers is a model that does not think: everything is reply.
  private var thinks: Bool { !start.isEmpty && !end.isEmpty }

  mutating func feed(_ chunk: String) -> [MlxEvent] {
    guard thinks else { return reply(chunk) }
    var text = pending + chunk
    pending = ""
    var events: [MlxEvent] = []
    while !text.isEmpty {
      let marker = inside ? end : start
      if let found = text.range(of: marker) {
        let before = String(text[..<found.lowerBound])
        events += inside ? thought(before) : reply(before)
        inside.toggle()
        text = String(text[found.upperBound...])
        continue
      }
      // Hold back what may be the first characters of the marker.
      let keep = Self.partialSuffix(of: text, prefixing: marker)
      let ready = String(text.dropLast(keep))
      pending = String(text.suffix(keep))
      events += inside ? thought(ready) : reply(ready)
      break
    }
    return events
  }

  mutating func finish() -> [MlxEvent] {
    let rest = pending
    pending = ""
    return inside ? thought(rest) : reply(rest)
  }

  private func thought(_ text: String) -> [MlxEvent] {
    text.isEmpty ? [] : [.reasoning(text)]
  }

  private mutating func reply(_ text: String) -> [MlxEvent] {
    var text = text
    if !replyStarted {
      text = String(text.drop { $0.isWhitespace })
      if text.isEmpty { return [] }
      replyStarted = true
    }
    return [.text(text)]
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
      && (content == other.content
        || content.trimmingCharacters(in: .whitespacesAndNewlines)
          == other.content.trimmingCharacters(in: .whitespacesAndNewlines))
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

/// Values as JSON text, the keys sorted so the same values are the same text
/// — a tool's schema is compared by it. Anything that will not serialise is
/// an empty object.
func jsonText(_ value: Any) -> String {
  guard JSONSerialization.isValidJSONObject(value),
    let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
  else { return "{}" }
  return String(decoding: data, as: UTF8.self)
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
