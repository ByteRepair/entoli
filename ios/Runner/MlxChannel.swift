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
    let channel = MlxChannel(name: "agent_chat/mlx", messenger: messenger)
    #if os(iOS)
    channel.stopOffScreen()
    #endif
    instance = channel
  }

  /// Off screen, iOS refuses an app's GPU work, so a reply there could only
  /// fail at its next command buffer and a load would end the app. Replies
  /// are stopped as the app leaves, each ending in `background`, and a
  /// reply, load or restore asked for meanwhile is refused.
  private let screen = Screen()

  #if os(iOS)
  private func stopOffScreen() {
    screen.offScreen = UIApplication.shared.applicationState == .background
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      screen.leave()
      Task { @MainActor in await self.stopGenerations() }
    }
    center.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.screen.offScreen = false }
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
      answer(result, code: "load") { [screen] in
        if screen.offScreen { throw OffScreen() }
        try await Mlx.load(model, directory, limits: MlxLimits(channel: args))
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
      answer(result) { [screen] in
        // Not restored is a reply that starts over, which is all it can do.
        if screen.offScreen { return false }
        return await Mlx.restore(model, from: path)
      }
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
    guard !screen.offScreen else { return sendOffScreen(id) }
    // A reply the app left the screen during ended for that, whatever it
    // ended in and whether or not the app is back by then.
    let departures = screen.departures
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
        case .done(let prompt, let generated, let peak, let budget):
          var done: [String: Any] = [
            "id": id, "finish": "stop", "inputTokens": prompt, "outputTokens": generated,
            "peakBytes": peak,
          ]
          if let budget { done["budgetBytes"] = budget }
          self?.send("done", done)
        @unknown default: break
        }
      }
    } catch where screen.departures != departures {
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

/// Whether the app is off screen, and how many times it has left: set on
/// the main thread, read by the channel's tasks.
private final class Screen: @unchecked Sendable {
  private let lock = NSLock()
  private var away = false
  private var left = 0

  var offScreen: Bool {
    get { lock.withLock { away } }
    set { lock.withLock { away = newValue } }
  }

  var departures: Int { lock.withLock { left } }

  func leave() {
    lock.withLock {
      away = true
      left += 1
    }
  }
}

private struct OffScreen: Error, CustomStringConvertible {
  var description: String { "The model can load only while Entoli is on screen." }
}
