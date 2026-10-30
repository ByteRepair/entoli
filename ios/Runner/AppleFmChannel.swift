#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
// The MLX models ride the same `LanguageModelSession` the system model does,
// through `EntoliMLX` — tool/apple/mlx, prebuilt into the XCFramework both
// Runners link — which answers on any OS and gates on its own.
import EntoliMLX

/// The Apple half of the `agent_chat/apple_fm` channel — `AppleFm` and its
/// client are the Dart half — compiled into both Runners. The system model
/// is the OS's own: the availability the handshake reports, and one
/// generation per ask, is the whole of what this class owns for it. An MLX
/// model is loaded from the directory Dart downloaded it to and kept
/// resident (`EntoliMLX`'s `Mlx`) until Dart evicts it; Dart decides
/// residency.
///
/// **A tool call is reported and ended, not run.** The agent in Dart owns
/// the loop the way it owns every other model's — approvals, the recorder
/// and the projections hang off that ownership — so `BridgeTool` throws the
/// moment it has forwarded a call, and the generation is cancelled here
/// before a framework that would have fed the report back into the model
/// can carry on underneath a conversation that has stopped listening.
///
/// **The history is seeded as text.** Prompt and response entries, the tool
/// calls worded inline, because a transcript that replays the framework's
/// own tool segments would owe the pairing semantics of
/// `Transcript.ToolCalls`/`ToolOutput` to a hand-run for their exactness,
/// and what a 3B model reads out of an inline wording is the same facts
/// either way.
class AppleFmChannel: NSObject {
  private static var instance: AppleFmChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    instance = AppleFmChannel(messenger: messenger)
  }

  private let channel: FlutterMethodChannel

  /// The generations in flight, by id — the handle a stop reaches the
  /// running generation through. Written on the main thread only: the
  /// handler inserts, and everything the generation itself does to the
  /// dictionary is posted, so a background Task never touches it.
  private var generations: [String: Task<Void, Never>] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_chat/apple_fm", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func send(_ method: String, _ arguments: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(method, arguments: arguments)
    }
  }

  private func availabilityReason() -> String {
    guard #available(iOS 26.0, macOS 26.0, *) else { return "os" }
    switch SystemLanguageModel.default.availability {
    case .available: return "available"
    case .unavailable(.deviceNotEligible): return "device-not-eligible"
    case .unavailable(.appleIntelligenceNotEnabled): return "not-enabled"
    case .unavailable(.modelNotReady): return "not-ready"
    case .unavailable: return "other"
    }
  }

  /// `load`, `evict` and `evictAll`: the residency Dart decides. A load
  /// that fails answers a `FlutterError` whose message is the reason, which
  /// is what the settings row shows.
  private func residency(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let model = args["model"] as? String ?? ""
    let reply = { (value: Any?) in DispatchQueue.main.async { result(value) } }
    Task.detached(priority: .userInitiated) {
      do {
        switch call.method {
        case "load":
          try await Mlx.load(model, args["directory"] as? String ?? "")
        case "evict":
          await Mlx.evict(model)
        default:
          await Mlx.evictAll()
        }
        reply(nil)
      } catch {
        reply(FlutterError(code: "load", message: "\(error)", details: nil))
      }
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "handshake":
      result(["reason": availabilityReason(), "mlx": Mlx.isAvailable])
    case "generate":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      // Held before the reply, so a cancel racing the start finds the task.
      // Retained until the generation ends, which is what breaks the cycle
      // the captured self would otherwise hold.
      let task = Task.detached(priority: .userInitiated) {
        await self.generate(id, args)
      }
      generations[id] = task
      result(nil)
    case "cancel":
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      finishGeneration(id)
      result(nil)
    case "load", "evict", "evictAll":
      residency(call, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finishGeneration(_ id: String) {
    DispatchQueue.main.async { [weak self] in
      self?.generations.removeValue(forKey: id)?.cancel()
    }
  }

  /// One generation: the history as the transcript, the prompt on top, and
  /// the text streamed out as it is produced. Nothing is held here between
  /// asks — the Dart client composes every request whole.
  private func generate(_ id: String, _ args: [String: Any]) async {
    // Every exit, the early ones included, or the task stays in `generations`.
    defer { finishGeneration(id) }
    guard #available(iOS 26.0, macOS 26.0, *) else {
      send("error", [
        "id": id, "code": "os",
        "message": "This OS carries no Foundation Models framework.",
      ])
      return
    }
    do {
      try await runGeneration(id, args)
    } catch is BridgeHandoff {
      // The tool's own throw racing its cancellation below it; the client
      // has already ended its stream on the report. Nothing is said.
    } catch is CancellationError {
      // A stop, or the tool that reported and stopped the generation:
      // cancelled, not failed, so nothing is said.
    } catch {
      if #available(iOS 27.0, macOS 27.0, *) {
        // The typed failures the framework throws now; a `false` is the
        // untyped ones, said as they are.
        if mapError(id, error) { return }
      }
      send("error", ["id": id, "code": "other", "message": "\(error)"])
    }
  }

  @available(iOS 26.0, macOS 26.0, *)
  private func runGeneration(_ id: String, _ args: [String: Any]) async throws {
    let model = args["model"] as? String ?? ""
    let instructions = args["instructions"] as? String ?? ""
    let prompt = args["prompt"] as? String ?? ""
    let temperature = args["temperature"] as? Double

    var tools = [any Tool]()
    for spec in (args["tools"] as? [[String: Any]]) ?? [] {
      // A tool whose schema will not convert is left out rather than
      // half-offered: a call the framework cannot decode is the worse
      // failure of the two.
      guard let name = spec["name"] as? String,
            let dynamic = schema(spec["schema"] as? [String: Any] ?? [:], name),
            let parameters = try? GenerationSchema(root: dynamic, dependencies: [])
      else { continue }
      tools.append(BridgeTool(
        name: name,
        description: spec["description"] as? String ?? "",
        parameters: parameters,
        report: { [weak self] name, json in
          self?.toolCall(id, name, json)
        }))
    }

    var entries = [Transcript.Entry]()
    // A seeded transcript's instructions are where the session reads its
    // tools' definitions from, so the entry is owed wherever there are tools.
    if !instructions.isEmpty || !tools.isEmpty {
      entries.append(.instructions(Transcript.Instructions(
        segments: instructions.isEmpty
          ? [] : [.text(Transcript.TextSegment(content: instructions))],
        toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
    }
    for entry in (args["history"] as? [[String: Any]]) ?? [] {
      guard let text = entry["text"] as? String, !text.isEmpty else { continue }
      let isAssistant = entry["role"] as? String == "assistant"
      let segment = Transcript.Segment.text(
        Transcript.TextSegment(content: text))
      entries.append(isAssistant
          ? .response(Transcript.Response(assetIDs: [], segments: [segment]))
          : .prompt(Transcript.Prompt(segments: [segment])))
    }

    let session = try await sessionFor(
      model, args["directory"] as? String, tools, Transcript(entries: entries))
    let stream = session.streamResponse(
      to: prompt,
      options: GenerationOptions(temperature: temperature))
    // The snapshots arrive cumulative — `content` is the generation so far,
    // not the increment — and the client appends frames as deltas, so only
    // the suffix past what was last said crosses the channel. A snapshot
    // that rewrote rather than extended cannot be said as a delta and is
    // skipped; the framework's content only grows.
    var sent = ""
    for try await part in stream {
      let text: String = part.content
      guard text.hasPrefix(sent), text != sent else { continue }
      send("text", ["id": id, "text": String(text.dropFirst(sent.count))])
      sent = text
    }

    // The session keeps the request's counts after it has streamed (iOS 27
    // and later); a turn's compact threshold reads them off the done frame.
    // Everything before a 27 runtime says nothing, and the estimate stands.
    var usage = [String: Any]()
    if #available(iOS 27.0, macOS 27.0, *) {
      let counts = session.usage
      let input = counts.input.totalTokenCount
      let output = counts.output.totalTokenCount
      if input > 0 || output > 0 {
        usage = [
          "inputTokens": input,
          "outputTokens": output,
          "cachedTokens": counts.input.cachedTokenCount,
          "reasoningTokens": counts.output.reasoningTokenCount,
        ]
      }
    }
    var done = ["id": id, "finish": "stop"] as [String: Any]
    done.merge(usage) { first, _ in first }
    send("done", done)
  }

  /// A generation with a `directory` is an MLX model's, built on the kept
  /// instance — loaded first where Dart's load has not run or was evicted
  /// under it. Without one it is the system model's.
  @available(iOS 26.0, macOS 26.0, *)
  private func sessionFor(
    _ model: String, _ directory: String?, _ tools: [any Tool], _ transcript: Transcript
  ) async throws -> LanguageModelSession {
    guard let directory else {
      return LanguageModelSession(
        model: .default, tools: tools, transcript: transcript)
    }
    return try await Mlx.session(model, directory, tools: tools, transcript: transcript)
  }

  private func toolCall(_ id: String, _ name: String, _ arguments: String) {
    send("toolCall", ["id": id, "name": name, "arguments": arguments])
    // The generation stops here even where the framework would have carried
    // on: the client stops reading at this frame, and this is what makes the
    // reported call the only one a turn answers.
    finishGeneration(id)
  }

  @available(iOS 27.0, macOS 27.0, *)
  /// `true` when the error was one of the framework's typed failures and has
  /// been said.
  private func mapError(_ id: String, _ error: Error) -> Bool {
    switch error {
    case let modelError as LanguageModelError:
      send("error", ["id": id, "code": code(of: modelError), "message": "\(modelError)"])
      return true
    case let assets as SystemLanguageModel.Error:
      send("error", ["id": id, "code": "assets", "message": "\(assets)"])
      return true
    default:
      return false
    }
  }
}

/// What `BridgeTool` throws the moment it has forwarded its call.
struct BridgeHandoff: Error {}

/// One of the agent's tools, as the framework sees it. The arguments are the
/// `schema` the Dart side sent, converted below into the framework's dynamic
/// schema — so decoding is the framework's, guided generation included, and
/// what reaches Dart is the JSON the call carried.
@available(iOS 26.0, macOS 26.0, *)
struct BridgeTool: Tool {
  let name: String
  let description: String
  var parameters: GenerationSchema

  typealias Arguments = GeneratedContent

  let report: @Sendable (_ name: String, _ arguments: String) -> Void

  func call(arguments: GeneratedContent) async throws -> String {
    report(name, arguments.jsonString)
    throw BridgeHandoff()
  }
}

@available(iOS 26.0, macOS 26.0, *)
extension AppleFmChannel {
  /// The framework's failures, in the words the Dart side's error map acts
  /// on — short tokens, no prose, the model's own `\(error)` riding beside.
  @available(iOS 27.0, macOS 27.0, *)
  private func code(of error: LanguageModelError) -> String {
    switch error {
    case .contextSizeExceeded: return "context"
    case .rateLimited: return "rate-limit"
    case .guardrailViolation: return "guardrail"
    case .refusal: return "guardrail"
    case .unsupportedLanguageOrLocale: return "language"
    case .timeout: return "resources"
    default: return "other"
    }
  }

  /// A JSON schema, as the agent's tools carry it, into the framework's
  /// dynamic schema: objects, the scalar leaves, arrays and enums. A shape
  /// outside those degrades to a String leaf — a tool arg the model then
  /// writes as prose in one field, which is the honest shrink rather than a
  /// refusal.
  /// shortcut: no numeric/length guides, when a tool's quality says one is
  /// wanted.
  ///
  /// **Every named node is named by its path**, rooted at the tool's name:
  /// the framework compiles all the tools' schemas into one grammar, and a
  /// nested object or enum sharing a name with a root is read as a reference
  /// back to that root — `#`, which the tool-aware constraints cannot resolve,
  /// and every turn offering the tool then fails before a token. The `title`
  /// a schema carries is not unique either, so it is not used.
  private func schema(_ json: [String: Any], _ path: String) -> DynamicGenerationSchema? {
    switch json["type"] as? String {
    case "object":
      let required = Set((json["required"] as? [String]) ?? [])
      var properties = [DynamicGenerationSchema.Property]()
      for (name, spec) in (json["properties"] as? [String: Any]) ?? [:] {
        guard let spec = spec as? [String: Any],
              let schema = self.schema(spec, "\(path)_\(name)")
        else { continue }
        properties.append(DynamicGenerationSchema.Property(
          name: name,
          description: spec["description"] as? String,
          schema: schema,
          isOptional: !required.contains(name)))
      }
      return DynamicGenerationSchema(
        name: path,
        description: json["description"] as? String,
        properties: properties)
    case "array":
      if let items = json["items"] as? [String: Any],
         let element = schema(items, "\(path)_item") {
        return DynamicGenerationSchema(arrayOf: element)
      }
      return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
    case "integer":
      return DynamicGenerationSchema(type: Int.self)
    case "number":
      return DynamicGenerationSchema(type: Double.self)
    case "boolean":
      return DynamicGenerationSchema(type: Bool.self)
    case "string":
      // An enum is the model's list of answers, which is what the guide is
      // for; anything else is one free string.
      let choices = (json["enum"] as? [String] ?? []).filter { !$0.isEmpty }
      if choices.count > 1 {
        return DynamicGenerationSchema(name: path, anyOf: choices)
      }
      return DynamicGenerationSchema(type: String.self)
    default:
      return DynamicGenerationSchema(type: String.self)
    }
  }
}
