#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
// The MLX models are `EntoliMLX`'s — tool/apple/mlx, prebuilt into the
// XCFramework both Runners link — which answers on any OS and gates on its
// own.
import EntoliMLX

/// The Swift half of `agent_chat/mlx` — `MlxEngine` is the Dart half —
/// compiled into both Runners and registered only where the models run: the
/// model host on macOS, the app itself on iOS. A process that never
/// registers it has no way to load a model, which is what keeps MLX's GPU
/// work out of the process that draws the Mac's window.
///
/// A model is loaded from the directory Dart downloaded it to and kept
/// (`EntoliMLX`'s `Mlx`) until Dart evicts it, with the conversation its
/// cache holds; Dart decides which are loaded. See "The MLX models" in
/// ios/AGENTS.md.
final class MlxChannel: GenerationChannel {
  private static var instance: MlxChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    instance = MlxChannel(name: "agent_chat/mlx", messenger: messenger)
  }

  /// Every generation cancelled, returning once each has ended: what a model
  /// host does before it leaves, so no generation is still encoding GPU work
  /// as the process goes.
  @MainActor static func stopAll() async {
    await instance?.stopGenerations()
  }

  override func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let model = args["model"] as? String ?? ""
    switch call.method {
    case "load", "evict":
      residency(call.method, model, args, result)
    case "generate":
      startGeneration(call, result, generate)
    case "save", "restore":
      let path = args["path"] as? String ?? ""
      let saving = call.method == "save"
      Task {
        let ok =
          saving
          ? await Mlx.save(model, to: path) : await Mlx.restore(model, from: path)
        DispatchQueue.main.async { result(ok) }
      }
    case "usage":
      Task {
        let usage = await Mlx.usage(model)
        DispatchQueue.main.async {
          result(usage.map { ["weightBytes": $0.weightBytes, "tokens": $0.tokens] })
        }
      }
    default:
      super.handle(call: call, result: result)
    }
  }

  /// `load` and `evict`: the residency Dart decides. A load that fails
  /// answers a `FlutterError` whose message is the reason, which is what the
  /// settings row shows.
  private func residency(
    _ method: String, _ model: String, _ args: [String: Any],
    _ result: @escaping FlutterResult
  ) {
    let reply = { (value: Any?) in DispatchQueue.main.async { result(value) } }
    Task.detached(priority: .userInitiated) {
      do {
        if method == "load" {
          try await Mlx.load(model, args["directory"] as? String ?? "")
        } else {
          await Mlx.evict(model)
        }
        reply(nil)
      } catch {
        reply(FlutterError(code: "load", message: "\(error)", details: nil))
      }
    }
  }

  /// One generation: the whole conversation in the OpenAI shape the Dart
  /// client already has, of which `EntoliMLX` reads only what the model's
  /// cache does not hold.
  private func generate(_ id: String, _ args: [String: Any]) async {
    do {
      try await Mlx.generate(
        args["model"] as? String ?? "",
        messages: (args["messages"] as? [[String: Any]] ?? []).map(MlxMessage.init(channel:)),
        tools: (args["tools"] as? [[String: Any]] ?? []).map(MlxTool.init(channel:)),
        temperature: args["temperature"] as? Double
      ) { [weak self] event in
        switch event {
        case .reasoning(let text): self?.send("reasoning", ["id": id, "text": text])
        case .text(let text): self?.send("text", ["id": id, "text": text])
        case .toolCall(let call):
          self?.send("toolCall", [
            "id": id, "callId": call.id, "name": call.name, "arguments": call.arguments,
          ])
        case .done(let prompt, let generated):
          self?.send("done", [
            "id": id, "finish": "stop", "inputTokens": prompt, "outputTokens": generated,
          ])
        @unknown default: break
        }
      }
    } catch is CancellationError {
      // A stop: cancelled, not failed, so nothing is said.
    } catch is MlxUnloaded {
      // Not a stop the turn asked for: it is waiting, and is told why its
      // reply ended.
      sendError(id, "unloaded", "The model was unloaded.")
    } catch {
      sendError(id, "other", "\(error)")
    }
  }
}
