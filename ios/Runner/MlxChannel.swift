#if os(iOS)
import Flutter
import UIKit
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
    #if os(iOS)
    instance?.stopOffScreen()
    #endif
  }

  /// Off screen, iOS refuses an app's GPU work, so a reply there could only
  /// fail at its next command buffer. It is stopped as the app leaves, and
  /// one asked for meanwhile is refused, both ending in `background`.
  private let offScreen = Flag()

  #if os(iOS)
  private func stopOffScreen() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      offScreen.value = true
      Task { @MainActor in await self.stopGenerations() }
    }
    center.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.offScreen.value = false }
  }
  #endif

  /// Every generation cancelled, returning once each has ended: what a model
  /// host does before it leaves, so no generation is still encoding GPU work
  /// as the process goes.
  @MainActor static func stopAll() async {
    await instance?.stopGenerations()
  }

  /// `load` and `evict` are the residency Dart decides: a load that fails
  /// answers a `FlutterError` whose message is the reason, which is what the
  /// settings row shows.
  override func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let model = args["model"] as? String ?? ""
    let path = args["path"] as? String ?? ""
    switch call.method {
    case "load":
      let directory = args["directory"] as? String ?? ""
      answer(result, code: "load") {
        try await Mlx.load(model, directory)
        return nil
      }
    case "evict":
      answer(result) {
        await Mlx.evict(model)
        return nil
      }
    case "generate":
      startGeneration(call, result, generate)
    case "save":
      answer(result) { await Mlx.save(model, to: path) }
    case "restore":
      answer(result) { await Mlx.restore(model, from: path) }
    case "usage":
      answer(result) {
        await Mlx.usage(model).map { ["weightBytes": $0.weightBytes, "tokens": $0.tokens] }
      }
    default:
      super.handle(call: call, result: result)
    }
  }

  /// One generation: the whole conversation in the OpenAI shape the Dart
  /// client already has, of which `EntoliMLX` reads only what the model's
  /// cache does not hold.
  private func generate(_ id: String, _ args: [String: Any]) async {
    // Dart always sends one; the fallback is its default, for a caller that
    // somehow did not.
    let maxTokens = args["maxTokens"] as? Int ?? 8192
    guard !offScreen.value else { return sendOffScreen(id) }
    do {
      try await Mlx.generate(
        args["model"] as? String ?? "",
        messages: (args["messages"] as? [[String: Any]] ?? []).map(MlxMessage.init(channel:)),
        tools: (args["tools"] as? [[String: Any]] ?? []).map(MlxTool.init(channel:)),
        temperature: args["temperature"] as? Double,
        maxTokens: maxTokens
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
    } catch where offScreen.value {
      // Whatever it ended in — the stop, or the GPU refusing first — it
      // ended because the app left the screen.
      sendOffScreen(id)
    } catch is CancellationError {
      // A stop: cancelled, not failed, so nothing is said.
    } catch is MlxUnloaded {
      // Not a stop the turn asked for: it is waiting, and is told why its
      // reply ended.
      sendError(id, "unloaded", "The model was unloaded.")
    } catch let failure as MlxFailure {
      sendError(id, failure.code, failure.description)
    } catch {
      sendError(id, "other", "\(error)")
    }
  }

  private func sendOffScreen(_ id: String) {
    sendError(id, "background", "The app left the screen.")
  }
}

/// A flag set on the main thread and read by a generation's task.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false

  var value: Bool {
    get { lock.withLock { raised } }
    set { lock.withLock { raised = newValue } }
  }
}
