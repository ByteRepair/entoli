#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// A method channel whose generations run as tasks and answer in frames —
/// `reasoning`, `text`, `toolCall`, `done`, `error`, each carrying the id it
/// was asked under — which Dart's `ChannelGeneration` reads. The system model
/// (`AppleFmChannel`) and the MLX models (`MlxChannel`) are both one of
/// these, each on a channel of its own; what they share is the bookkeeping a
/// stop reaches a running generation through.
class GenerationChannel: NSObject {
  let channel: FlutterMethodChannel

  /// The generations in flight, by id — the handle a stop reaches the
  /// running generation through. Written on the main thread only: the
  /// handler inserts, and everything the generation itself does to the
  /// dictionary is posted, so a background Task never touches it.
  private var generations: [String: Task<Void, Never>] = [:]

  init(name: String, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  /// `cancel`, which every such channel answers; a subclass answers the rest
  /// and hands what it does not know here.
  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "cancel":
      let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
      finishGeneration(id)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func send(_ method: String, _ arguments: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(method, arguments: arguments)
    }
  }

  /// The one ending a generation that failed: every generation ends with
  /// `done` or this.
  func sendError(_ id: String, _ code: String, _ message: String) {
    send("error", ["id": id, "code": code, "message": message])
  }

  /// Starts the generation the call's `id` names and answers at once, its
  /// frames following on the channel. Held before the reply, so a cancel
  /// racing the start finds the task; retained until the generation ends,
  /// which is what breaks the cycle the captured self would otherwise hold —
  /// so every exit of `body`, the early ones included, ends it here.
  func startGeneration(
    _ call: FlutterMethodCall, _ result: FlutterResult,
    _ body: @escaping (String, [String: Any]) async -> Void
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    generations[id] = Task.detached(priority: .userInitiated) {
      await body(id, args)
      self.finishGeneration(id)
    }
    result(nil)
  }

  func finishGeneration(_ id: String) {
    DispatchQueue.main.async { [weak self] in
      self?.generations.removeValue(forKey: id)?.cancel()
    }
  }

  /// Every generation cancelled, returning once each has ended.
  @MainActor func stopGenerations() async {
    let tasks = Array(generations.values)
    tasks.forEach { $0.cancel() }
    for task in tasks { await task.value }
  }
}
