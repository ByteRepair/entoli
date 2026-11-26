import Foundation
internal import MLX

/// What the app planned for one model (`BudgetPlan` in Dart): everything MLX
/// does for it inside `budget`, the rest of the app keeping what is left.
public struct MlxLimits: Sendable {
  /// Bytes this model may take: its weights, its state, the prefill's working
  /// memory, its share of the buffer cache and its KV cache.
  public let budget: Int
  /// What MLX may keep of the buffers it frees.
  public let cache: Int
  /// The most tokens of conversation it has room for.
  public let context: Int
  /// The prefill's chunk, short enough that its working memory fits.
  public let prefillStep: Int

  /// Nil where the app sent no plan, which leaves MLX its own defaults.
  public init?(channel map: [String: Any]) {
    guard let budget = map["budget"] as? Int, let cache = map["cache"] as? Int,
      let context = map["context"] as? Int, let prefillStep = map["prefillStep"] as? Int
    else { return nil }
    self.budget = budget
    self.cache = cache
    self.context = context
    self.prefillStep = prefillStep
  }
}

/// MLX's share of this process: the sum of the loaded models' budgets, which
/// MLX's own limits are set to and a reply is stopped at. Measured by MLX's
/// counters, never the app's free memory, so the rest of the app is not
/// what moves the line.
///
/// MLX's soft limit only makes an evaluation wait for work in flight — its
/// allocator never fails at it — so `isOver`, checked after each prefill
/// chunk and each output chunk, is what holds MLX to the budget.
final class MlxBudget: @unchecked Sendable {
  static let shared = MlxBudget()

  private let lock = NSLock()
  private var planned: [String: MlxLimits] = [:]
  private var unplanned: Set<String> = []

  /// The loaded models' budgets summed; nil while none is planned or one is
  /// not, a model with no plan having no budget to hold anything to.
  private var total: Int? {
    guard unplanned.isEmpty, !planned.isEmpty else { return nil }
    return planned.values.reduce(0) { $0 + $1.budget }
  }

  /// Evicted models' budgets, still counted: their buffers are freed a moment
  /// after their unload returns, and a reply on another model must not be
  /// stopped for memory that is on its way out. Dropped once MLX holds no
  /// more than the loaded models' budgets.
  private var draining = 0

  /// MLX's own, read before anything changes them.
  private let ownMemoryLimit = Memory.memoryLimit
  private let ownCacheLimit = Memory.cacheLimit

  func admit(_ id: String, _ limits: MlxLimits?) {
    lock.withLock {
      if let limits { planned[id] = limits } else { unplanned.insert(id) }
      apply()
    }
  }

  func release(_ id: String) {
    lock.withLock {
      if let limits = planned.removeValue(forKey: id) { draining += limits.budget }
      unplanned.remove(id)
      apply()
    }
  }

  /// MLX's budget as it stands, evicted models' still counted.
  var bytes: Int? { lock.withLock { total.map { $0 + draining } } }

  /// Whether MLX holds more than every loaded model was planned to.
  var isOver: Bool {
    let used = Memory.activeMemory + Memory.cacheMemory
    return lock.withLock {
      guard let total else { return false }
      if draining > 0 && used <= total {
        draining = 0
        apply()
      }
      return used > total + draining
    }
  }

  /// With no budget MLX keeps its own limits, and with nothing loaded its
  /// cache keeps nothing: an evicted model's buffers are freed a moment after
  /// its unload returns, and are handed back as they are.
  private func apply() {
    if let total {
      Memory.memoryLimit = total + draining
      Memory.cacheLimit = planned.values.reduce(0) { $0 + $1.cache }
    } else {
      draining = 0
      Memory.memoryLimit = ownMemoryLimit
      Memory.cacheLimit = unplanned.isEmpty ? 0 : ownCacheLimit
    }
  }
}
